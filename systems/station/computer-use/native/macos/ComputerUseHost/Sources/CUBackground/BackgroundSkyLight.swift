import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

enum BackgroundSkyLight {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias SetIntFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer,
        Int32,
        UInt32
    ) -> AnyObject?
    private typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias PostEventRecordToFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias AXUIElementGetWindowFn = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private struct EventPost {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn?
        let msgSendFactory: FactoryMsgSendFn?
        let messageClass: AnyClass?
        let factorySelector: Selector
    }

    private static let eventPost: EventPost? = {
        loadSkyLight()
        guard let postToPid = symbol("SLEventPostToPid", as: PostToPidFn.self) else {
            return nil
        }

        return EventPost(
            postToPid: postToPid,
            setAuthMessage: symbol("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
            msgSendFactory: symbol("objc_msgSend", as: FactoryMsgSendFn.self),
            messageClass: NSClassFromString("SLSEventAuthenticationMessage"),
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    private static let setIntField = resolveSkyLight("SLEventSetIntegerValueField", as: SetIntFieldFn.self)
    private static let setWindowLocation = resolveSkyLight("CGEventSetWindowLocation", as: SetWindowLocationFn.self)
    private static let getFrontProcess = resolveSkyLight("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
    private static let postEventRecordTo = resolveSkyLight("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let getProcessForPID = resolveHIServices("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let getWindowForAXElement = resolveHIServices(
        "_AXUIElementGetWindow",
        as: AXUIElementGetWindowFn.self
    )

    static var canPostEvents: Bool {
        eventPost != nil
    }

    static var canFocusWithoutRaise: Bool {
        getFrontProcess != nil && getProcessForPID != nil && postEventRecordTo != nil
    }

    @discardableResult
    static func postToPid(
        _ pid: pid_t,
        event: CGEvent,
        attachAuthMessage: Bool
    ) -> Bool {
        guard let eventPost else { return false }
        if attachAuthMessage,
           let setAuthMessage = eventPost.setAuthMessage,
           let msgSendFactory = eventPost.msgSendFactory,
           let messageClass = eventPost.messageClass,
           let record = extractEventRecord(from: event),
           let message = msgSendFactory(
               messageClass as AnyObject,
               eventPost.factorySelector,
               record,
               pid,
               0
           )
        {
            setAuthMessage(event, message)
        }
        eventPost.postToPid(pid, event)
        return true
    }

    @discardableResult
    static func setIntegerField(_ event: CGEvent, field: UInt32, value: Int64) -> Bool {
        guard let setIntField else { return false }
        setIntField(event, field, value)
        return true
    }

    @discardableResult
    static func setWindowLocalPoint(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let setWindowLocation else { return false }
        setWindowLocation(event, point)
        return true
    }

    @discardableResult
    static func focusWithoutRaise(targetPID: pid_t, windowID: CGWindowID) -> Bool {
        guard
            let getFrontProcess,
            let getProcessForPID,
            let postEventRecordTo
        else {
            return false
        }

        var previousPSN = [UInt32](repeating: 0, count: 2)
        var targetPSN = [UInt32](repeating: 0, count: 2)

        guard previousPSN.withUnsafeMutableBytes({ getFrontProcess($0.baseAddress!) == 0 }) else {
            return false
        }
        guard targetPSN.withUnsafeMutableBytes({ getProcessForPID(targetPID, $0.baseAddress!) == 0 }) else {
            return false
        }

        var eventRecord = [UInt8](repeating: 0, count: 0xF8)
        eventRecord[0x04] = 0xF8
        eventRecord[0x08] = 0x0D
        let rawWindowID = UInt32(windowID)
        eventRecord[0x3C] = UInt8(rawWindowID & 0xFF)
        eventRecord[0x3D] = UInt8((rawWindowID >> 8) & 0xFF)
        eventRecord[0x3E] = UInt8((rawWindowID >> 16) & 0xFF)
        eventRecord[0x3F] = UInt8((rawWindowID >> 24) & 0xFF)

        eventRecord[0x8A] = 0x02
        let defocused = previousPSN.withUnsafeBytes { psn in
            eventRecord.withUnsafeBufferPointer { record in
                postEventRecordTo(psn.baseAddress!, record.baseAddress!) == 0
            }
        }

        eventRecord[0x8A] = 0x01
        let focused = targetPSN.withUnsafeBytes { psn in
            eventRecord.withUnsafeBufferPointer { record in
                postEventRecordTo(psn.baseAddress!, record.baseAddress!) == 0
            }
        }

        return defocused && focused
    }

    static func cgWindowID(forAXWindow element: AXUIElement) -> CGWindowID? {
        guard let getWindowForAXElement else { return nil }
        var windowID: CGWindowID = 0
        guard getWindowForAXElement(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let pointer = slot.pointee {
                return pointer
            }
        }
        return nil
    }

    private static func resolveSkyLight<T>(_ name: String, as type: T.Type) -> T? {
        loadSkyLight()
        return symbol(name, as: type)
    }

    private static func resolveHIServices<T>(_ name: String, as type: T.Type) -> T? {
        loadHIServices()
        return symbol(name, as: type)
    }

    private static func loadSkyLight() {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }

    private static func loadHIServices() {
        _ = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
    }

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
