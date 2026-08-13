import Foundation

/// The result of one local, read-only interface inspection.
///
/// This deliberately contains no daemon data.  The GUI uses it as the source
/// of truth for values that macOS can report without asking a privileged
/// process to perform any work.
struct ReadOnlyRefreshResult: Sendable {
  let generation: UInt64
  let interfaces: [InterfaceSnapshot]
  let completedAt: Date
  let errorDescription: String?
}

/// Coalesces user-initiated, local interface reads.
///
/// The provider is the Shared read-only adapter (`getifaddrs`,
/// SystemConfiguration and CoreWLAN).  In particular, this controller must
/// never call XPC or a daemon: pressing Refresh remains safe when the daemon
/// is stopped, unavailable, or being repaired.
@MainActor
final class ReadOnlyRefreshController {
  private let provider: any ReadOnlyInterfaceProviding
  private var inFlight: Task<ReadOnlyRefreshResult, Never>?
  private var nextGeneration: UInt64 = 0

  init(provider: any ReadOnlyInterfaceProviding = SystemReadOnlyInterfaceProvider()) {
    self.provider = provider
  }

  /// Starts at most one read at a time.  Concurrent callers receive the same
  /// completed result instead of issuing another system query.
  func refresh() async -> ReadOnlyRefreshResult {
    if let inFlight {
      return await inFlight.value
    }

    nextGeneration &+= 1
    let generation = nextGeneration
    let provider = provider
    let task = Task.detached(priority: .userInitiated) {
      do {
        return ReadOnlyRefreshResult(
          generation: generation,
          interfaces: try provider.interfaces(),
          completedAt: Date(),
          errorDescription: nil
        )
      } catch {
        return ReadOnlyRefreshResult(
          generation: generation,
          interfaces: [],
          completedAt: Date(),
          errorDescription: error.localizedDescription
        )
      }
    }

    inFlight = task
    let result = await task.value
    if result.generation == nextGeneration {
      inFlight = nil
    }
    return result
  }
}
