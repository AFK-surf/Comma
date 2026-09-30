import AppKit
import Darwin
import Foundation

final class TrackpadEdgeSwipeMonitor {
    var panelVisibility: CGFloat {
        get {
            lock.withLock { visibilityProgress }
        }
        set {
            lock.withLock {
                visibilityProgress = newValue
                if newValue <= 0.002 {
                    stableVisibilityProgress = 0
                } else if newValue >= 0.998 {
                    stableVisibilityProgress = 1
                }
            }
        }
    }

    private let onProgress: (CGFloat) -> Void
    private let onComplete: (Bool) -> Void
    private let onStatusChange: (String) -> Void
    private let lock = NSLock()

    private var createDeviceList: MTDeviceCreateList?
    private var deviceList: CFArray?
    private var devices: [MTDeviceRef] = []
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var gesture: GestureState?
    private var registerCallback: MTRegisterContactFrameCallback?
    private var startDevice: MTDeviceStart?
    private var stopDevice: MTDeviceStop?
    private var unregisterCallback: MTUnregisterContactFrameCallback?
    private var inputGeneration = 0
    private var isInputEnabled = true
    private var visibilityProgress: CGFloat = 0
    private var stableVisibilityProgress: CGFloat = 0

    private static let requiredFingerCount = 2
    private static let edgeActivationMaxX: CGFloat = 0.12
    private static let closeActivationMaxX: CGFloat = 0.36
    private static let horizontalActivationDistance: CGFloat = 0.035
    private static let verticalCancelDistance: CGFloat = 0.026
    private static let horizontalDominanceRatio: CGFloat = 1.55

    init(
        onProgress: @escaping (CGFloat) -> Void,
        onComplete: @escaping (Bool) -> Void,
        onStatusChange: @escaping (String) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onStatusChange = onStatusChange
    }

    func start() {
        setInputEnabled(true)
        Self.activeMonitor = self

        guard loadFramework() else { return }
        guard let createDeviceList, let registerCallback, let startDevice else {
            publishStatus("multitouch symbols missing")
            return
        }

        guard let unmanagedDeviceList = createDeviceList() else {
            publishStatus("no multitouch devices")
            return
        }

        let deviceList = unmanagedDeviceList.takeRetainedValue()
        self.deviceList = deviceList

        let count = CFArrayGetCount(deviceList)
        guard count > 0 else {
            publishStatus("no multitouch devices")
            return
        }

        devices = (0..<count).compactMap { index in
            guard let rawDevice = CFArrayGetValueAtIndex(deviceList, index) else { return nil }
            return UnsafeMutableRawPointer(mutating: rawDevice)
        }

        withFrameworkOutputRedirectedToStandardError {
            devices.forEach { device in
                registerCallback(device, Self.contactFrameCallback)
                startDevice(device, 0)
            }
        }

        publishStatus("multitouch listening: \(devices.count) device\(devices.count == 1 ? "" : "s")")
    }

    func stop() {
        setInputEnabled(false)
        guard !devices.isEmpty else { return }

        devices.forEach { device in
            unregisterCallback?(device, Self.contactFrameCallback)
            stopDevice?(device)
        }
        devices.removeAll()

        if Self.activeMonitor === self {
            Self.activeMonitor = nil
        }
    }

    /// Invalidates every queued callback and drops the in-flight gesture when
    /// forced-close ownership moves to the controller. Re-enabling starts a
    /// fresh gesture from the then-current panel visibility.
    func setInputEnabled(_ isEnabled: Bool) {
        lock.withLock {
            inputGeneration += 1
            isInputEnabled = isEnabled
            gesture = nil
        }
    }

    deinit {
        stop()
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    private func loadFramework() -> Bool {
        if frameworkHandle != nil { return true }

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            let error = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            publishStatus("multitouch unavailable: \(error)")
            return false
        }

        frameworkHandle = handle
        createDeviceList = loadSymbol("MTDeviceCreateList", from: handle, as: MTDeviceCreateList.self)
        registerCallback = loadSymbol("MTRegisterContactFrameCallback", from: handle, as: MTRegisterContactFrameCallback.self)
        unregisterCallback = loadSymbol("MTUnregisterContactFrameCallback", from: handle, as: MTUnregisterContactFrameCallback.self)
        startDevice = loadSymbol("MTDeviceStart", from: handle, as: MTDeviceStart.self)
        stopDevice = loadSymbol("MTDeviceStop", from: handle, as: MTDeviceStop.self)

        return true
    }

    private func process(contacts rawPointer: UnsafeMutableRawPointer?, count: Int32, timestamp: Double) {
        guard let rawPointer else {
            finishCurrentGesture()
            return
        }

        guard count == Self.requiredFingerCount else {
            count > Self.requiredFingerCount ? settleCurrentGestureToStableEndpoint() : finishCurrentGesture()
            return
        }

        let pointer = rawPointer.bindMemory(to: MTContact.self, capacity: Int(count))
        var points: [CGPoint] = []
        points.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let contact = pointer[index]
            let x = CGFloat(contact.normalized.position.x)
            let y = CGFloat(contact.normalized.position.y)

            guard x.isFinite, y.isFinite, x >= -0.15, x <= 1.15, y >= -0.15, y <= 1.15 else {
                continue
            }

            points.append(CGPoint(x: x, y: y))
        }

        guard points.count == Self.requiredFingerCount else {
            points.count > Self.requiredFingerCount ? settleCurrentGestureToStableEndpoint() : finishCurrentGesture()
            return
        }

        let averageX = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
        let averageY = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)

        lock.lock()
        guard isInputEnabled else {
            gesture = nil
            lock.unlock()
            return
        }
        let currentVisibility = visibilityProgress
        let generation = inputGeneration

        if gesture == nil {
            gesture = GestureState(
                startX: averageX,
                startY: averageY,
                lastX: averageX,
                lastY: averageY,
                mode: nil,
                startVisibility: currentVisibility,
                maxProgress: currentVisibility,
                lastProgress: currentVisibility
            )
        }

        guard var currentGesture = gesture else {
            lock.unlock()
            return
        }

        let deltaX = averageX - currentGesture.startX
        let deltaY = averageY - currentGesture.startY
        let absDeltaX = abs(deltaX)
        let absDeltaY = abs(deltaY)

        if currentGesture.mode == nil {
            if absDeltaY > Self.verticalCancelDistance, absDeltaY > absDeltaX * Self.horizontalDominanceRatio {
                currentGesture.mode = .ignored
            } else if absDeltaX > Self.horizontalActivationDistance, absDeltaX > absDeltaY * Self.horizontalDominanceRatio {
                if currentGesture.startVisibility >= 0.98, currentGesture.startX <= Self.edgeActivationMaxX, deltaX > 0 {
                    currentGesture.mode = .ignored
                } else if currentGesture.startVisibility < 0.98, currentGesture.startX <= Self.edgeActivationMaxX, deltaX > 0 {
                    currentGesture.mode = .opening
                } else if currentGesture.startVisibility > 0.72, currentGesture.startX <= Self.closeActivationMaxX, deltaX < 0 {
                    currentGesture.mode = .closing
                } else {
                    currentGesture.mode = .ignored
                }
            }
        }

        var outputProgress: CGFloat?

        switch currentGesture.mode {
        case .opening:
            let progress = min(max(currentGesture.startVisibility + deltaX / 0.30, 0), 1)
            currentGesture.maxProgress = max(currentGesture.maxProgress, progress)
            currentGesture.lastProgress = progress
            outputProgress = progress
        case .closing:
            let progress = min(max(currentGesture.startVisibility + deltaX / 0.30, 0), 1)
            currentGesture.maxProgress = max(currentGesture.maxProgress, progress)
            currentGesture.lastProgress = progress
            outputProgress = progress
        case .ignored:
            break
        case nil:
            break
        }

        currentGesture.lastX = averageX
        currentGesture.lastY = averageY
        gesture = currentGesture
        lock.unlock()

        if let outputProgress {
            dispatchProgress(outputProgress, generation: generation)
        }
    }

    private func finishCurrentGesture() {
        let completion: (gesture: GestureState, generation: Int)? = lock.withLock {
            guard isInputEnabled else {
                gesture = nil
                return nil
            }
            let completedGesture = gesture
            gesture = nil
            guard let completedGesture else { return nil }
            return (completedGesture, inputGeneration)
        }

        guard let completion, let mode = completion.gesture.mode else { return }

        let shouldOpen: Bool
        switch mode {
        case .opening:
            shouldOpen = completion.gesture.maxProgress > 0.36
                || completion.gesture.lastProgress > 0.30
        case .closing:
            shouldOpen = completion.gesture.lastProgress > 0.58
        case .ignored:
            return
        }

        dispatchCompletion(shouldOpen, generation: completion.generation)
    }

    private func settleCurrentGestureToStableEndpoint() {
        let completion: (shouldOpen: Bool, generation: Int)? = lock.withLock {
            guard isInputEnabled else {
                gesture = nil
                return nil
            }
            guard gesture != nil else { return nil }
            gesture = nil
            return (stableVisibilityProgress >= 0.5, inputGeneration)
        }

        guard let completion else { return }
        dispatchCompletion(
            completion.shouldOpen,
            generation: completion.generation
        )
    }

    private func dispatchProgress(_ progress: CGFloat, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldDeliverInput(generation: generation) else { return }
            self.onProgress(progress)
        }
    }

    private func dispatchCompletion(_ shouldOpen: Bool, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldDeliverInput(generation: generation) else { return }
            self.onComplete(shouldOpen)
        }
    }

    private func shouldDeliverInput(generation: Int) -> Bool {
        lock.withLock {
            isInputEnabled && inputGeneration == generation
        }
    }

    private func publishStatus(_ status: String) {
        FileHandle.standardError.write(Data("[CommaSideChatHost] trackpad: \(status)\n".utf8))
        DispatchQueue.main.async { [onStatusChange] in
            onStatusChange(status)
        }
    }

    private func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// MultitouchSupport writes device-family diagnostics with C `printf`.
    /// Flush while fd 1 points at stderr so stdout remains a JSON-only wire.
    private func withFrameworkOutputRedirectedToStandardError(_ body: () -> Void) {
        fflush(stdout)
        let savedStandardOutput = dup(STDOUT_FILENO)
        guard savedStandardOutput >= 0 else {
            body()
            return
        }
        defer { close(savedStandardOutput) }

        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            body()
            return
        }

        body()
        fflush(stdout)
        _ = dup2(savedStandardOutput, STDOUT_FILENO)
    }

    private static weak var activeMonitor: TrackpadEdgeSwipeMonitor?

    private static let contactFrameCallback: MTContactFrameCallback = { _, contacts, count, timestamp, _ in
        activeMonitor?.process(contacts: contacts, count: count, timestamp: timestamp)
        return 0
    }
}

private enum GestureMode {
    case opening
    case closing
    case ignored
}

private struct GestureState {
    var startX: CGFloat
    var startY: CGFloat
    var lastX: CGFloat
    var lastY: CGFloat
    var mode: GestureMode?
    var startVisibility: CGFloat
    var maxProgress: CGFloat
    var lastProgress: CGFloat
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTDeviceStart = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStop = @convention(c) (MTDeviceRef) -> Void
private typealias MTRegisterContactFrameCallback = @convention(c) (MTDeviceRef, MTContactFrameCallback?) -> Void
private typealias MTUnregisterContactFrameCallback = @convention(c) (MTDeviceRef, MTContactFrameCallback?) -> Void
private typealias MTContactFrameCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout
    var total: Float
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var reserved1: Int32
    var reserved2: Int32
    var density: Float
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
