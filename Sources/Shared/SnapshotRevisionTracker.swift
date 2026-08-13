import Foundation

/// Accepts monotonic snapshots from one daemon instance and resets cleanly
/// when launchd starts a new instance whose revision begins at zero.
struct SnapshotRevisionTracker: Sendable {
  private(set) var instanceID: UUID?
  private(set) var revision: UInt64 = 0
  private var retiredInstanceIDs: Set<UUID> = []
  private var retiredInstanceOrder: [UUID] = []

  mutating func accepts(_ snapshot: DaemonSnapshot) -> Bool {
    if let instanceID {
      if retiredInstanceIDs.contains(snapshot.instanceID) {
        return false
      }
      if instanceID == snapshot.instanceID, snapshot.revision < revision {
        return false
      }
      if instanceID != snapshot.instanceID {
        retire(instanceID)
        revision = 0
      }
    }
    instanceID = snapshot.instanceID
    revision = max(revision, snapshot.revision)
    return true
  }

  mutating func reset() {
    instanceID = nil
    revision = 0
    retiredInstanceIDs.removeAll()
    retiredInstanceOrder.removeAll()
  }

  private mutating func retire(_ identifier: UUID) {
    guard retiredInstanceIDs.insert(identifier).inserted else { return }
    retiredInstanceOrder.append(identifier)
    if retiredInstanceOrder.count > 16 {
      let oldest = retiredInstanceOrder.removeFirst()
      retiredInstanceIDs.remove(oldest)
    }
  }
}
