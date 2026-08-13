import Foundation

enum AutomationTrigger: Equatable, Sendable {
  case beforeSleep
  case afterWake
  case networkChange
}

/// Pure trigger planner. It only identifies work that should become pending;
/// `SafetyPolicy` still decides whether queued work may execute now.
enum AutomationPlanner {
  static func interfaceIDsToQueue(
    for trigger: AutomationTrigger,
    settings: AutomationSettings,
    previous: [String: InterfaceSnapshot] = [:],
    current: [String: InterfaceSnapshot]
  ) -> Set<String> {
    switch trigger {
    case .beforeSleep:
      guard settings.prepareRotationBeforeSleep else { return [] }
      return randomPolicyIDs(in: current)

    case .afterWake:
      guard settings.rotateAfterWake else { return [] }
      return randomPolicyIDs(in: current)

    case .networkChange:
      guard settings.rotateWhenInterfaceBecomesInactive else { return [] }
      return Set(current.values.compactMap { interface in
        guard interface.policy == .random,
              let old = previous[interface.id],
              old.isActive || old.isWiFiAssociated,
              !interface.isActive,
              !interface.isWiFiAssociated else { return nil }
        return interface.id
      })
    }
  }

  private static func randomPolicyIDs(in interfaces: [String: InterfaceSnapshot]) -> Set<String> {
    Set(interfaces.values.compactMap { interface in
      interface.policy == .random ? interface.id : nil
    })
  }
}
