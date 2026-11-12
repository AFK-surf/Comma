// The Mac's system output for a display's view (ScreenStreamSession `listen`) from a Core Audio process tap: every
// process's sound but the Comma apps' (`AudioProcess.leftOut`: the app, its Electron helpers with Chromium's audio
// service, this helper). ScreenCaptureKit cannot leave out the audio service: it is no app that a filter can name. The
// tap names Core Audio's process objects, and follows them as they come and go (`kAudioHardwarePropertyProcessObjectList`):
// a running tap takes a new exclusion list (`kAudioTapPropertyDescription`) with no gap in its sound.
//
// The tap is the input of a private aggregate device with no sub-device: no microphone is part of it, and the helper
// asks for none. Its IOProc gives PCM to SystemAudio (`tapped`), 48 kHz stereo as ScreenCaptureKit's: the station and
// the client see the same packets. Silence is not sent, as ScreenCaptureKit sends nothing while nothing plays.
//
// macOS asks for "System Audio Recording Only" (TCC kTCCServiceAudioCapture), which Screen Recording does not give.
// While it is not decided, making the IOProc waits for the person's answer. Thus the tap starts only when the grant is
// there (`SystemAudioGrant`); else the view's sound is ScreenCaptureKit's, and the grant is asked once
// (docs/desktop-screen.md "Clipboard and sound"). Cue's own: still.fail has no tap.
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// A Core Audio process object, as `leftOut` tells the Comma apps apart.
struct AudioProcess: SoundApp, Equatable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String

    /// The processes whose sound is left out: the Comma apps (`ScreenStreamSession.isComma`) and this helper.
    static func leftOut(_ processes: [AudioProcess], own: pid_t = getpid()) -> [AudioProcess] {
        processes.filter { ScreenStreamSession.isComma($0.bundleIdentifier) || $0.pid == own }
    }
}

/// "System Audio Recording Only" (TCC kTCCServiceAudioCapture) for this process, which a process tap needs.
enum SystemAudioGrant {
    case granted, denied, undecided, unknown

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let asked = NSLock()
    private static var askedOnce = false

    /// What macOS says without asking (still.fail's Files.swift `preflight`): 0 granted, 1 denied, 2 it would ask.
    static func now() -> SystemAudioGrant {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .undecided
        default: return .unknown
        }
    }

    /// Asks macOS to show its prompt, once while the helper runs. It does not wait for the answer: the next view with
    /// sound uses the tap when the person allows it.
    static func ask() {
        asked.lock()
        defer { asked.unlock() }
        guard !askedOnce, let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { return }
        askedOnce = true
        let request = unsafeBitCast(symbol, to: Request.self)
        DispatchQueue.global(qos: .utility).async { request(service, nil) { _ in } }
    }
}

@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private let sink: SystemAudio
    /// The process list's changes come on it.
    private let queue = DispatchQueue(label: "CommaComputerUse.ScreenAudioTap")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var excluded: [AudioObjectID] = []
    private var processes: AudioObjectPropertyListenerBlock?

    init(sink: SystemAudio) {
        self.sink = sink
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        init(_ call: String, _ status: OSStatus) { description = "\(call) failed (\(status))" }
    }

    /// Starts the tap. Call it only with the grant (`SystemAudioGrant.granted`): without it, making the IOProc waits
    /// for the person's answer to macOS's prompt.
    func start() throws {
        excluded = AudioProcess.leftOut(Self.processes()).map(\.object)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Comma screen sound"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        self.description = description
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure("AudioHardwareCreateProcessTap", status) }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Comma screen sound",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
        guard status == noErr else { stop(); throw Failure("AudioHardwareCreateAggregateDevice", status) }
        var format = AudioStreamBasicDescription()
        status = Self.read(tap, kAudioTapPropertyFormat, &format)
        guard status == noErr else { stop(); throw Failure("kAudioTapPropertyFormat", status) }
        let convert: Converter
        do { convert = try Converter(format) } catch { stop(); throw error }
        let sink = self.sink
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, time, _, _ in
            guard let pcm = convert.stereo(input), pcm.contains(where: { $0 != 0 }) else { return }
            let host = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : mach_absolute_time()
            sink.tapped(pcm, at: HostClock.stamp(uptime: Int64(AudioConvertHostTimeToNanos(host) / 1000)))
        }
        guard status == noErr else { stop(); throw Failure("AudioDeviceCreateIOProcID", status) }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw Failure("AudioDeviceStart", status) }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.follow() }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, changed) == noErr {
            processes = changed
        }
        // A process that came between the list read and the listener.
        queue.async { [weak self] in self?.follow() }
    }

    /// The exclusion made again from the process list, on `queue`: a Comma process that started is left out.
    private func follow() {
        guard let description, tap != kAudioObjectUnknown else { return }
        let now = AudioProcess.leftOut(Self.processes()).map(\.object)
        guard now != excluded else { return }
        excluded = now
        description.processes = now
        var address = Self.address(kAudioTapPropertyDescription)
        var value = description
        _ = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
    }

    func stop() {
        if let processes {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, processes)
            self.processes = nil
        }
        queue.sync {}
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Core Audio

    static func processes() -> [AudioProcess] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).map { object in
            var pid: pid_t = -1
            _ = read(object, kAudioProcessPropertyPID, &pid)
            var bundle: Unmanaged<CFString>?
            let said = read(object, kAudioProcessPropertyBundleID, &bundle) == noErr
            let identifier = said ? (bundle?.takeRetainedValue() as String?) ?? "" : ""
            return AudioProcess(object: object, pid: pid, bundleIdentifier: identifier)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }
}

/// The tap's PCM as interleaved stereo PCM16 at 48 kHz (SystemAudio's packets): as it is at 48 kHz, else resampled.
@available(macOS 14.2, *)
private final class Converter: @unchecked Sendable {
    private let format: AudioStreamBasicDescription
    private let resample: AVAudioConverter?
    private let input: AVAudioFormat
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SystemAudio.rate), channels: 2, interleaved: true)!

    init(_ format: AudioStreamBasicDescription) throws {
        var format = format
        self.format = format
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerFrame > 0, let input = AVAudioFormat(streamDescription: &format) else {
            throw SystemAudioTap.Failure("the tap's format is not linear PCM")
        }
        self.input = input
        if Int(format.mSampleRate) == SystemAudio.rate {
            resample = nil
        } else {
            guard let made = AVAudioConverter(from: input, to: output) else { throw SystemAudioTap.Failure("no converter from \(format.mSampleRate) Hz") }
            resample = made
        }
    }

    func stereo(_ list: UnsafePointer<AudioBufferList>) -> [Int16]? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let frames = Int(first.mDataByteSize / format.mBytesPerFrame)
        guard let resample else {
            let raw = buffers.map { UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize)) }
            return SystemAudio.interleave(raw, frames: frames, channels: Int(format.mChannelsPerFrame), planar: planar, float: float)
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: input, bufferListNoCopy: list, deallocator: nil),
            let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames * SystemAudio.rate / Int(format.mSampleRate) + 16))
        else { return nil }
        var given = false
        var error: NSError?
        resample.convert(to: target, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, let data = target.audioBufferList.pointee.mBuffers.mData else { return nil }
        let raw = UnsafeRawBufferPointer(start: data, count: Int(target.frameLength) * 8)
        return SystemAudio.interleave([raw], frames: Int(target.frameLength), channels: 2, planar: false, float: true)
    }
}
