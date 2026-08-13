import Foundation

let coordinator = DaemonCoordinator()
let monitor = SystemEventMonitor { event in coordinator.handleSystemEvent(event) }
do {
  try monitor.start()
} catch {
  let message = "System event monitoring failed: \(error.localizedDescription)"
  coordinator.reportHealthFault(message)
  FileHandle.standardError.write(Data("MACDancer daemon warning: \(message)\n".utf8))
}

do {
  try DaemonListener(coordinator: coordinator).run()
} catch {
  FileHandle.standardError.write(Data("MACDancer daemon failed: \(error.localizedDescription)\n".utf8))
  exit(EXIT_FAILURE)
}
