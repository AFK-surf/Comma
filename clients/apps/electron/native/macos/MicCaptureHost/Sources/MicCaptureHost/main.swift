// MicCaptureHost — a tiny Main-owned helper that streams the default
// microphone as raw little-endian Int16 mono PCM on stdout.
// --list-devices emits bounded JSON without requesting microphone permission.
// --device <UID|default> selects exactly that input; it never changes the OS default.
//
// Protocol
//   argv:    --sample-rate <hz>      (default 48000)
//   stdout:  raw Int16 LE mono frames at the requested rate, nothing else
//   stderr:  one JSON line per event: {"event":"ready"|"warning"|"error",...}
//   stdin:   EOF (or SIGTERM) means stop; exit 0 after the engine is torn down
//   exit 2:  audio engine failure
//   exit 3:  microphone access denied by macOS
//
// Voice processing is enabled on the input node so the far end of a call
// coming out of the speakers is echo-cancelled instead of recorded twice.

import AppKit
import AVFoundation
import CoreAudio
import Foundation

// MARK: - Input device selection
//
// `AVAudioEngine.inputNode` follows the system default input. On machines
// with virtual or aggregate devices (BlackHole, Loopback, screen-recording
// helpers) that default is often a many-channel device carrying no speech,
// which downmixes to silence. Prefer a real microphone when the default
// looks like that.

struct InputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: UInt32
    let inputChannels: UInt32

    var isVirtualOrAggregate: Bool {
        transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeUnknown
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
}

func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + $1.mNumberChannels }
}

func deviceName(_ device: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    return audioProperty(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name) ? (name as String) : "?"
}

func deviceUID(_ device: AudioDeviceID) -> String {
    var uid: CFString = "" as CFString
    return audioProperty(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid) ? (uid as String) : ""
}

func listInputDevices() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        var transport: UInt32 = 0
        _ = audioProperty(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        return InputDevice(id: id, name: deviceName(id), uid: deviceUID(id), transport: transport, inputChannels: channels)
    }
}

/// Honor the explicit input, including virtual devices. Default means macOS default.
func chooseInputDevice(_ uid: String) -> InputDevice? {
    let devices = listInputDevices()
    if uid != "default" { return devices.first { $0.uid == uid } }
    var defaultID: AudioDeviceID = 0
    _ = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, &defaultID)
    return devices.first { $0.id == defaultID }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle = FileHandle.standardError

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var payload: [String: Any] = ["event": event]
        for (key, value) in fields { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.write(Data((line + "\n").utf8))
    }
}

final class MicHost: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "comma.mic.write")
    private let stdout = FileHandle.standardOutput
    private let log: EventLog
    private let requestedDevice: String
    private let targetSampleRate: Double
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var sourceSampleRate: Double = 0
    private var sourceChannels: UInt32 = 0
    private var stopped = false
    private var voiceProcessing = true
    private var silentFrames = 0
    private var restartedWithoutVoiceProcessing = false
    private var chosenDevice: AudioDeviceID?

    init(targetSampleRate: Double, device: String, log: EventLog) {
        self.requestedDevice = device
        self.targetSampleRate = targetSampleRate
        self.log = log
    }

    func start() {
        let input = engine.inputNode
        var chosenName = "system default"
        guard let device = chooseInputDevice(requestedDevice), let unit = input.audioUnit else {
            log.emit("error", ["message": "selected microphone is unavailable"])
            exit(2)
        }
        do {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                chosenName = device.name
                chosenDevice = device.id
            } else {
                log.emit("error", ["message": "could not select input device \(device.name): \(status)"])
                exit(2)
            }
        }
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                voiceProcessing = false
                log.emit("warning", ["message": "voice processing unavailable: \(error.localizedDescription)"])
            }
        }

        let sourceFormat = input.outputFormat(forBus: 0)
        sourceChannels = sourceFormat.channelCount
        // The voice-processing IO unit only produces input while the graph
        // renders, so route the input through a muted mixer to the output.
        if voiceProcessing {
            engine.connect(input, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0
        }
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            log.emit("error", ["message": "no microphone input format"])
            exit(2)
        }
        guard let monoSource = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: monoSource, to: target) else {
            log.emit("error", ["message": "cannot build converter"])
            exit(2)
        }
        self.converter = converter
        self.targetFormat = target
        self.sourceSampleRate = sourceFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { [self] buffer, _ in
            self.handle(buffer)
        }

        do {
            try engine.start()
        } catch {
            if voiceProcessing {
                // The voice-processing graph can refuse to initialize on some
                // devices; a plain microphone is better than no microphone.
                log.emit("warning", ["message": "voice processing engine failed (\(error.localizedDescription)); retrying without it"])
                input.removeTap(onBus: 0)
                engine.stop()
                // A fresh engine: the failed voice-processing graph leaves the
                // old input unit in a state that refuses further configuration.
                engine = AVAudioEngine()
                voiceProcessing = false
                restartedWithoutVoiceProcessing = true
                start()
                return
            }
            log.emit("error", ["message": "engine start failed: \(error.localizedDescription)"])
            exit(2)
        }
        log.emit("ready", [
            "device": chosenName,
            "voiceProcessing": voiceProcessing,
            "sampleRate": targetSampleRate,
            "sourceSampleRate": sourceFormat.sampleRate,
            "sourceChannels": Int(sourceFormat.channelCount),
        ])
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
        let source = buffer.floatChannelData, let dest = mono.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if channels <= 2 {
            // Average a stereo mic; a mono mic passes through.
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += source[c][i] }
                dest[0][i] = sum / Float(channels)
            }
        } else {
            // Many-channel formats (voice-processing IO) carry speech on channel 0.
            for i in 0..<frames { dest[0][i] = source[0][i] }
        }
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(dest[0][i])) }
        trackSilence(peak: peak, frames: frames)

        let ratio = targetFormat.sampleRate / max(sourceSampleRate, 1)
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return mono
        }
        if status == .error || conversionError != nil { return }
        let outFrames = Int(output.frameLength)
        guard outFrames > 0, let channel = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: channel, count: outFrames * MemoryLayout<Int16>.size)
        writeQueue.async { [self] in
            if self.stopped { return }
            self.stdout.write(data)
        }
    }

    /// Voice processing sometimes yields pure silence; after ~2 s of it,
    /// rebuild the engine without voice processing rather than record nothing.
    private func trackSilence(peak: Float, frames: Int) {
        guard voiceProcessing, !restartedWithoutVoiceProcessing else { return }
        if peak > 0 {
            silentFrames = 0
            return
        }
        silentFrames += frames
        if Double(silentFrames) >= sourceSampleRate * 2 {
            restartedWithoutVoiceProcessing = true
            DispatchQueue.main.async { [self] in
                self.log.emit("warning", ["message": "voice processing produced silence; restarting without it"])
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.engine = AVAudioEngine()
                self.voiceProcessing = false
                self.silentFrames = 0
                self.start()
            }
        }
    }

    func stopAndExit(_ code: Int32) -> Never {
        writeQueue.sync {
            if !stopped {
                stopped = true
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        exit(code)
    }
}

func parseSampleRate() -> Double {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--sample-rate"), index + 1 < args.count,
       let value = Double(args[index + 1]), value >= 8_000, value <= 192_000 {
        return value
    }
    return 48_000
}

let log = EventLog()
let arguments = CommandLine.arguments
// Main supplies both private file paths. This mode never starts microphone capture.
if arguments.contains("--encode-recording") {
    guard arguments.count == 4, arguments[1] == "--encode-recording" else { exit(2) }
    do {
        try autoreleasepool {
            try encodeRecording(input: URL(fileURLWithPath: arguments[2]),
                                output: URL(fileURLWithPath: arguments[3]))
        }
        exit(0)
    } catch {
        log.emit("error", ["message": "Recording compression failed: \(error.localizedDescription)"])
        exit(2)
    }
}
if let index = arguments.firstIndex(of: "--app-icon"), index + 1 < arguments.count {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments[index + 1]) else { exit(2) }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(2) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
    FileHandle.standardOutput.write(data)
    exit(0)
}
if arguments.contains("--list-devices") {
    var defaultID: AudioDeviceID = 0
    _ = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, &defaultID)
    let devices = listInputDevices().filter { !$0.uid.isEmpty }.prefix(128).map { device -> [String: Any] in
        ["id": device.uid, "label": device.name, "isDefault": device.id == defaultID]
    }
    if let data = try? JSONSerialization.data(withJSONObject: ["devices": devices]) {
        FileHandle.standardOutput.write(data)
        exit(0)
    }
    exit(2)
}
let deviceIndex = arguments.firstIndex(of: "--device")
let requestedDevice = deviceIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "default"
let host = MicHost(targetSampleRate: parseSampleRate(), device: requestedDevice, log: log)

// Stop on stdin EOF: Main closes our stdin to end the capture.
FileHandle.standardInput.readabilityHandler = { handle in
    if handle.availableData.isEmpty {
        host.stopAndExit(0)
    }
}
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { host.stopAndExit(0) }
termSource.resume()

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    host.start()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
            if granted {
                host.start()
            } else {
                log.emit("error", ["message": "microphone_denied"])
                exit(3)
            }
        }
    }
default:
    log.emit("error", ["message": "microphone_denied"])
    exit(3)
}

dispatchMain()
