import Darwin
import Foundation
import WorldbookTaskCLI

@main
struct WorldbookTaskTool {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    // No environment credentials enter an App target or a persisted profile.
    let allowed = ["WORLDBOOK_API_KEY", "WORLDBOOK_MODEL", "WORLDBOOK_BASE_URL"]
    let environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
    let task = Task { await WorldbookTaskCLI().run(arguments: arguments, environment: environment) }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
      // main() and this handler inherit MainActor isolation in Swift 6.
      // Delivering the handler on a global queue triggers a runtime trap.
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { task.cancel() }
      source.resume()
      return source
    }
    let result = await task.value
    signals.forEach { $0.cancel() }
    FileHandle.standardOutput.write(Data(result.output.utf8))
    FileHandle.standardError.write(Data(result.diagnostic.utf8))
    Darwin.exit(result.exitCode)
  }
}
