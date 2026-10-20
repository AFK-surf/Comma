import AVFoundation
import SwiftUI

/// The camera panel's state on the main actor. Session work happens in `CaptureEngine`.
@MainActor @Observable final class CameraModel {
    enum State: Equatable { case starting, running, denied, unavailable }

    private(set) var state = State.starting
    private(set) var flashOn = false
    private(set) var capturing = false
    /// Counts shutter presses, so the shutter haptic fires on the press itself.
    private(set) var shots = 0
    private var position = AVCaptureDevice.Position.back
    /// Made on the first start, off the main actor: a capture session and photo output take a while to build.
    /// The panel is rebuilt with the views around it, each time building a model that is then dropped, so the
    /// model itself must cost nothing.
    @ObservationIgnored private var engine: CaptureEngine?

    /// The configured session, for the preview, which attaches to it before it runs (see `run`).
    private(set) var session: AVCaptureSession?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }
        let engine: CaptureEngine
        if let existing = self.engine { engine = existing } else { engine = await Task.detached { CaptureEngine() }.value }
        self.engine = engine
        guard await engine.configure(position) else { state = .unavailable; return }
        session = engine.session
    }

    /// Starts the session once the preview has attached to it. Attaching to a session that is starting makes
    /// the main thread wait for the camera to come up, which stalls the card's animation. A session that does
    /// not start, as when another app holds the camera, shows the notice rather than the grey cover.
    func run() {
        engine?.start { [weak self] running in Task { @MainActor in self?.state = running ? .running : .unavailable } }
    }

    func stop() { engine?.stop() }

    func toggleFlash() { flashOn.toggle() }

    func flip() async {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        if await engine?.configure(next) == true { position = next }
    }

    /// One JPEG from the running session, or nil when the capture fails.
    func capture() async -> AttachmentImage? {
        guard state == .running, !capturing else { return nil }
        capturing = true
        shots += 1
        defer { capturing = false }
        guard let data = try? await engine?.capture(flash: flashOn) else { return nil }
        return AttachmentImage(data: data, type: .jpeg)
    }
}

/// Owns the capture session. AVFoundation wants every session change on one serial queue, so all of
/// them run on `queue`; that confinement is why this type can cross into the main-actor model.
final class CaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "surf.comma.camera")
    private var input: AVCaptureDeviceInput?
    /// Capture delegates live until their photo arrives; the output does not keep them.
    private var inFlight: [Int64: PhotoDelegate] = [:]

    /// Uses the wide camera at `position`. False when this device has none, as in Simulator.
    func configure(_ position: AVCaptureDevice.Position) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.useCamera(at: position)) }
        }
    }

    /// Queued in call order with `stop`, so a panel that has already gone never starts the camera after it.
    func start(started: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            started(self.session.isRunning)
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func capture(flash: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                if self.output.supportedFlashModes.contains(.on) { settings.flashMode = flash ? .on : .off }
                let id = settings.uniqueID
                let delegate = PhotoDelegate(continuation: continuation) { [weak self] in
                    guard let self else { return }
                    self.queue.async { self.inFlight[id] = nil }
                }
                self.inFlight[id] = delegate
                self.output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func useCamera(at position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let next = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        if let input { session.removeInput(input) }
        guard session.canAddInput(next) else {
            if let input { session.addInput(input) }
            return false
        }
        session.addInput(next)
        input = next
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        return true
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, any Error>
    private let finished: () -> Void

    init(continuation: CheckedContinuation<Data, any Error>, finished: @escaping () -> Void) {
        self.continuation = continuation
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            continuation.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
        }
        finished()
    }
}

/// The live preview, filling its frame.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// The preview is attached; the session can start.
    let attached: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        attached()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
