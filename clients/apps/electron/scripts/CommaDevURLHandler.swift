import Cocoa
import CoreServices

private let bundle = Bundle.main
private let electronExecutable = bundle.object(forInfoDictionaryKey: "CommaElectronExecutable") as? String
private let projectRoot = bundle.object(forInfoDictionaryKey: "CommaProjectRoot") as? String
private let buildFlavor = bundle.object(forInfoDictionaryKey: "CommaBuildFlavor") as? String
private let urlScheme = bundle.object(forInfoDictionaryKey: "CommaURLScheme") as? String

if CommandLine.arguments.contains("--install") {
  guard let urlScheme, let bundleIdentifier = bundle.bundleIdentifier else {
    fputs("Comma URL handler is missing its scheme or bundle identifier.\n", stderr)
    exit(2)
  }
  let status = LSSetDefaultHandlerForURLScheme(urlScheme as CFString, bundleIdentifier as CFString)
  exit(status == noErr ? 0 : 1)
}

final class CommaURLHandlerDelegate: NSObject, NSApplicationDelegate {
  private var forwarded = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let value = CommandLine.arguments.first(where: { $0.hasPrefix("\(urlScheme ?? "comma-dev")://") }) {
      forward(value)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      NSApplication.shared.terminate(nil)
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let value = urls.first?.absoluteString else {
      application.terminate(nil)
      return
    }
    forward(value)
  }

  private func forward(_ value: String) {
    guard !forwarded, let electronExecutable, let projectRoot else { return }
    forwarded = true

    let task = Process()
    task.executableURL = URL(fileURLWithPath: electronExecutable)
    task.arguments = [projectRoot, value]
    var environment = ProcessInfo.processInfo.environment
    if let buildFlavor { environment["COMMA_BUILD_FLAVOR"] = buildFlavor }
    task.environment = environment

    do {
      try task.run()
    } catch {
      fputs("Unable to forward Comma URL: \(error)\n", stderr)
    }
    NSApplication.shared.terminate(nil)
  }
}

let app = NSApplication.shared
let delegate = CommaURLHandlerDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
