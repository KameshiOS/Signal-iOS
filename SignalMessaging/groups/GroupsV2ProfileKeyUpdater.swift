//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalServiceKit
import Reachability

// Whenever we rotate our profile key, we need to update all
// v2 groups of which we are a non-pending member.

// This is laborious, but important. It is too expensive to
// do unless necessary (e.g. we don't want to check every
// group on launch), but important enough to do durably.
//
// This class has responsibility for tracking which groups
// need to be updated and for updating them.
class GroupsV2ProfileKeyUpdater {

    // MARK: - Dependencies

    private var tsAccountManager: TSAccountManager {
        return .sharedInstance()
    }

    private var databaseStorage: SDSDatabaseStorage {
        return .shared
    }

    private var profileManager: OWSProfileManager {
        return OWSProfileManager.shared()
    }

    private var groupsV2: GroupsV2 {
        return SSKEnvironment.shared.groupsV2
    }

    private var groupsV2Swift: GroupsV2Swift {
        return SSKEnvironment.shared.groupsV2 as! GroupsV2Swift
    }

    // MARK: -

    var reachability: Reachability?

    public required init() {
        reachability = Reachability.forInternetConnection()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(reachabilityChanged),
                                               name: .reachabilityChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didBecomeActive),
                                               name: .OWSApplicationDidBecomeActive,
                                               object: nil)
    }

    // MARK: -

    @objc func didBecomeActive() {
        AssertIsOnMainThread()

        AppReadiness.runNowOrWhenAppDidBecomeReady {
            self.tryToUpdateNext()
        }
    }

    @objc func reachabilityChanged() {
        AssertIsOnMainThread()

        AppReadiness.runNowOrWhenAppDidBecomeReady {
            self.tryToUpdateNext()
        }
    }

    // MARK: -

    // Stores the list of v2 groups that we need to update with our latest profile key.
    private let keyValueStore = SDSKeyValueStore(collection: "GroupsV2ProfileKeyUpdater")

    private func key(for groupId: Data) -> String {
        return groupId.hexadecimalString
    }

    public func scheduleAllGroupsV2ForProfileKeyUpdate(transaction: SDSAnyWriteTransaction) {
        guard let localAddress = tsAccountManager.localAddress else {
            owsFailDebug("missing local address")
            return
        }

        TSGroupThread.anyEnumerate(transaction: transaction) { (thread, _) in
            guard let groupThread = thread as? TSGroupThread else {
                return
            }
            let groupMembership = groupThread.groupModel.groupMembership
            // We only need to update v2 groups of which we are a full member.
            guard groupThread.isGroupV2Thread,
                groupMembership.isNonPendingMember(localAddress) else {
                    return
            }
            let groupId = groupThread.groupModel.groupId
            let key = self.key(for: groupId)
            self.keyValueStore.setData(groupId, key: key, transaction: transaction)
        }
    }

    @objc
    public func processProfileKeyUpdates() {
        tryToUpdateNext()
    }

    private let serialQueue = DispatchQueue(label: "SystemContactsFetcherQueue", qos: .background)

    // This property should only be accessed on serialQueue.
    private var isUpdating = false

    private func tryToUpdateNext(retryDelay: TimeInterval = 1) {
        guard CurrentAppContext().isMainAppAndActive else {
            return
        }
        guard let reachability = self.reachability,
            reachability.isReachable() else {
                return
        }

        serialQueue.async {
            guard !self.isUpdating else {
                // Only one update should be in flight at a time.
                return
            }
            let groupIds = self.databaseStorage.read { transaction in
                return self.keyValueStore.allDataValues(transaction: transaction)
            }
            guard let groupId = groupIds.first else {
                return
            }

            self.isUpdating = true

            firstly {
                self.tryToUpdate(groupId: groupId)
            }.done(on: .global() ) { _ in
                Logger.verbose("Updated profile key in group.")

                self.didSucceed(groupId: groupId)
            }.catch(on: .global() ) { error in
                Logger.warn("Failed: \(error).")

                switch error {
                case GroupsV2Error.shouldDiscard:
                    // If a non-recoverable error occurs (e.g. we've
                    // delete the thread from the database), give up.
                    self.markAsComplete(groupId: groupId)
                case GroupsV2Error.redundantChange:
                    // If the update is no longer necessary, skip it.
                    self.markAsComplete(groupId: groupId)
                case let networkManagerError as NetworkManagerError:
                    if networkManagerError.isNetworkConnectivityError {
                        // Retry later.
                        self.didFail(groupId: groupId, retryDelay: retryDelay)
                    } else {
                        switch networkManagerError.statusCode {
                        case 400, 401:
                            // If a non-recoverable error occurs (e.g. we've been kicked
                            // out of the group), give up.
                            self.markAsComplete(groupId: groupId)
                        default:
                            // Retry later.
                            self.didFail(groupId: groupId, retryDelay: retryDelay)
                        }
                    }
                default:
                    // This should never occur. If it does, we don't want
                    // to get stuck in a retry loop.
                    owsFailDebug("Unexpected error: \(error)")
                    self.markAsComplete(groupId: groupId)
                }
            }
        }
    }

    private func didSucceed(groupId: Data) {
        markAsComplete(groupId: groupId)
    }

    private func markAsComplete(groupId: Data) {
        serialQueue.async {
            self.databaseStorage.write { transaction in
                let key = self.key(for: groupId)
                self.keyValueStore.removeValue(forKey: key, transaction: transaction)
            }

            self.isUpdating = false

            self.tryToUpdateNext()
        }
    }

    private func didFail(groupId: Data,
                         retryDelay: TimeInterval) {
        serialQueue.asyncAfter(deadline: DispatchTime.now() + retryDelay) {
            self.isUpdating = false

            // Retry with exponential backoff.
            self.tryToUpdateNext(retryDelay: retryDelay * 2)
        }
    }

    private func tryToUpdate(groupId: Data) -> Promise<Void> {
        let profileKeyData = profileManager.localProfileKey().keyData
        guard let localAddress = tsAccountManager.localAddress else {
            owsFailDebug("missing local address")
            return Promise(error: GroupsV2Error.shouldDiscard)
        }

        return databaseStorage.read(.promise) { transaction in
            guard let groupThread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
                throw GroupsV2Error.shouldDiscard
            }
            return groupThread
        }.then(on: .global()) { (groupThread: TSGroupThread) throws -> Promise<TSGroupThread> in
            // Get latest group state from service and verify that this update is still necessary.
            return firstly {
                self.groupsV2Swift.fetchCurrentGroupV2Snapshot(groupModel: groupThread.groupModel)
            }.map(on: .global()) { (groupV2Snapshot: GroupV2Snapshot) throws -> TSGroupThread in
                guard groupV2Snapshot.groupMembership.isNonPendingMember(localAddress) else {
                    // We're not a full member, no need to update profile key.
                    throw GroupsV2Error.redundantChange
                }
                guard !groupV2Snapshot.profileKeys.values.contains(profileKeyData) else {
                    // Group state already has our current key.
                    throw GroupsV2Error.redundantChange
                }
                return groupThread
            }
        }.then(on: .global()) { (groupThread: TSGroupThread) throws -> Promise<Void> in
            return firstly {
                return GroupManager.ensureLocalProfileHasCommitmentIfNecessary()
            }.map(on: .global()) { () throws -> GroupsV2ChangeSet in
                let groupId = groupThread.groupModel.groupId
                guard let groupSecretParamsData = groupThread.groupModel.groupSecretParamsData else {
                    owsFailDebug("Missing groupSecretParamsData.")
                    throw GroupsV2Error.shouldDiscard
                }
                let changeSet = GroupsV2ChangeSetImpl(groupId: groupId,
                                                      groupSecretParamsData: groupSecretParamsData)
                changeSet.setShouldUpdateLocalProfileKey()
                return changeSet
            }.then(on: DispatchQueue.global()) { (changeSet: GroupsV2ChangeSet) -> Promise<TSGroupThread> in
                return self.groupsV2Swift.updateExistingGroupOnService(changeSet: changeSet)
            }.asVoid()
        }
    }
}
