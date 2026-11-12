import AVFoundation
import notify

/// The composer's recorder here: a simulator on a machine with no audio input never starts a real one. It takes the
/// microphone as the real one does, one recorder at a time, and leaves a file for the fixture server to write out.
/// With `--hold-microphone` a start lasts until the test posts `PerfSignal.releaseMicrophone`, so the test decides
/// what happens while it is under way.
final class FixtureRecorder: AVAudioRecorder, @unchecked Sendable {
    /// Open once the test released the microphone.
    private static let held: DispatchGroup = {
        let group = DispatchGroup()
        guard ProcessInfo.processInfo.arguments.contains("--hold-microphone") else { return group }
        group.enter()
        var token: Int32 = 0
        notify_register_dispatch(PerfSignal.releaseMicrophone.name, &token, .global()) { _ in group.leave() }
        return group
    }()
    nonisolated(unsafe) private static var taken = false
    private var running = false

    /// Listens for the release from launch: a test's post may come before the first recorder.
    static func listen() { _ = held }

    override func record(forDuration duration: TimeInterval) -> Bool {
        Self.held.wait()
        guard !Self.taken else { return false }
        Self.taken = true
        running = true
        return FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
    }

    override var isRecording: Bool { running }

    override func stop() {
        guard running else { return }
        running = false
        Self.taken = false
    }

    override func updateMeters() {}
    override func averagePower(forChannel channelNumber: Int) -> Float { -30 }
}
