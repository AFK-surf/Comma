import AppKit

final class NotchEventMonitor {
    private var globalMonitor: AnyObject?
    private var localMonitor: AnyObject?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
        } as AnyObject?

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
            return event
        } as AnyObject?
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }
}

@MainActor
final class NotchInteractionMonitor {
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?

    private var mouseDownEvent: NotchEventMonitor?
    private var mouseMovedEvent: NotchEventMonitor?

    func start() {
        mouseDownEvent = NotchEventMonitor(mask: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onMouseDown?(NSEvent.mouseLocation)
            }
        }
        mouseDownEvent?.start()

        mouseMovedEvent = NotchEventMonitor(mask: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onMouseMoved?(NSEvent.mouseLocation)
            }
        }
        mouseMovedEvent?.start()
    }

    func stop() {
        mouseDownEvent?.stop()
        mouseDownEvent = nil

        mouseMovedEvent?.stop()
        mouseMovedEvent = nil
    }
}
