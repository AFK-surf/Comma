import AppKit
import Foundation
import NotchKit
import SwiftUI

struct HostCommand: Decodable {
    var id: String?
    var method: String
    var payload: CommaNotchScenePayload?
}

struct HostEvent: Encodable {
    var type: String
    var id: String?
    var payload: EventPayload?
    var error: String?
}

struct EventPayload: Encodable {
    var running: Bool? = nil
    var hasActivity: Bool? = nil
    var method: String? = nil
    var action: String? = nil
    var value: String? = nil
}

@MainActor
final class NotchHost {
    // Without a physical notch the count side keeps half the title side,
    // never less than a three-digit count needs.
    private static let compactTrailingMinimumWidth: CGFloat = 24
    // AirDrop's compact title is a status sentence with nothing after it; a
    // longer one, such as a count of several files, widens its side.
    private static let airDropLeadingWidth: CGFloat = 196
    private static let airDropMaximumLeadingWidth: CGFloat = 320
    private static let airDropTrailingWidth: CGFloat = 16
    /// Long enough to look up from Settings and read the Notch, short enough
    /// to feel like a glance.
    private static let previewDuration: TimeInterval = 3.2

    private static let configuration = NotchConfiguration(
        screenSelectionPolicy: .builtInFirst,
        expandedPadding: .init(),
        maximumExpandedSize: CGSize(width: 600, height: 311),
        minimumExpandedSize: CGSize(width: 600, height: 160),
        materialStyle: .liquidGlass,
        liquidGlassHeight: 200,
        liquidGlassTransitionHeight: 86
    )

    private let controller = NotchController(configuration: NotchHost.configuration)

    /// Settings > General > Notch width, written by Main's `configure` before
    /// any scene. The default matches `notchSideWidthRange.default`.
    private var compactSideWidth: CGFloat = 156
    /// A width the reader is trying in Settings, shown once over the Task
    /// scene. AirDrop still comes first.
    private var preview: (task: CommaNotchScenePayloadTask, sideWidth: CGFloat)?
    private var previewEnd: DispatchWorkItem?
    private var running = false
    private var hasActivity = false
    private var notificationSequence = 0
    private var currentTitle = "Comma"
    private var currentSubtitle = "NotchKit is connected"
    private var currentDetail = "Electron can update, open, close, and pulse this SwiftUI notch surface through IPC."
    private var currentTasks: [CommaNotchScenePayloadTask] = []
    /// Main's AirDrop projection; while present it replaces the task scene.
    private var currentAirDrop: CommaNotchAirDropPresentation?
    private var autoOpenedAirDropRequestID: String?
    private var listTitle = "Conversation activity"
    private var listSubtitle = "Open a conversation to inspect its latest state."
    private var openChatLabel = "Open chat"

    func start() {
        guard !running else { return }
        running = true
        controller.start()
        emit(type: "ready", payload: .init(running: true, hasActivity: hasActivity, method: nil))
    }

    func handle(_ command: HostCommand) {
        do {
            switch command.method {
            case "start":
                start()
            case "configure":
                configure(command.payload)
            case "preview":
                showPreview(command.payload)
            case "stop":
                controller.stop()
                running = false
            case "show", "update":
                apply(command.payload, defaultActivity: true)
            case "hide":
                hasActivity = false
                currentTasks = []
                currentAirDrop = nil
                controller.update(scene: .hidden)
            case "open":
                controller.open()
            case "close":
                controller.close()
            case "toggle":
                controller.toggle()
            case "pulse":
                controller.pulse()
            case "status":
                break
            default:
                throw NSError(
                    domain: "NotchHost",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown command: \(command.method)"]
                )
            }

            emit(
                type: "ack",
                id: command.id,
                payload: .init(running: running, hasActivity: hasActivity, method: command.method)
            )
        } catch {
            emit(type: "error", id: command.id, error: error.localizedDescription)
        }
    }

    private func configure(_ payload: CommaNotchScenePayload?) {
        guard let width = payload?.compactSideWidth else { return }
        let sideWidth = CGFloat(width)
        guard sideWidth != compactSideWidth else { return }
        compactSideWidth = sideWidth

        // Only the Task activity takes the reader's width; AirDrop sizes to
        // its own sentence. A showing Notch follows the shell's own curve, so
        // its content and outline resize as one.
        guard currentAirDrop == nil, !currentTasks.isEmpty else { return }
        withAnimation(Self.configuration.animation) {
            controller.update(scene: makeScene())
        }
    }

    private func showPreview(_ payload: CommaNotchScenePayload?) {
        guard let title = payload?.title, let width = payload?.compactSideWidth else { return }
        previewEnd?.cancel()
        preview = (
            task: CommaNotchScenePayloadTask(
                conversationId: "preview",
                groupId: "preview",
                id: "preview",
                subtitle: "",
                title: title,
                updatedAt: 0,
                workspaceId: "preview"
            ),
            sideWidth: CGFloat(width)
        )
        // Arrives the way new activity does, so it reads as the real thing.
        // An open Notch folds back first: the preview is its compact width.
        // AirDrop is drawn ahead of any preview, so an open offer stays open.
        notificationSequence += 1
        if currentAirDrop == nil {
            controller.close()
        }
        controller.update(scene: makeScene())

        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.preview = nil
            self.previewEnd = nil
            self.controller.update(scene: self.makeScene())
        }
        previewEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDuration, execute: end)
    }

    private func apply(_ payload: CommaNotchScenePayload?, defaultActivity: Bool) {
        if let title = payload?.title {
            currentTitle = title
        }
        if let subtitle = payload?.subtitle {
            currentSubtitle = subtitle
        }
        if let detail = payload?.detail {
            currentDetail = detail
        }
        if let value = payload?.listTitle { listTitle = value }
        if let value = payload?.listSubtitle { listSubtitle = value }
        if let value = payload?.openChatLabel { openChatLabel = value }

        if let tasks = payload?.tasks {
            currentTasks = tasks.sorted { left, right in
                if left.updatedAt == right.updatedAt {
                    return left.id > right.id
                }
                return left.updatedAt > right.updatedAt
            }
            hasActivity = !currentTasks.isEmpty
        } else if payload?.airDrop == nil {
            hasActivity = payload?.hasActivity ?? defaultActivity
        }
        if payload?.notify == true {
            notificationSequence += 1
        }

        let previousAirDrop = currentAirDrop?.transfer
        if let airDrop = payload?.airDrop {
            currentAirDrop = airDrop.transfer.map(CommaNotchAirDropPresentation.init)
        }

        controller.update(scene: makeScene())

        // A new offer opens itself so its decision is one click away. Once it
        // is answered, expires, or the transfer ends, the Notch folds back.
        let airDrop = currentAirDrop?.transfer
        if let airDrop, airDrop.phase == .offer,
           airDrop.requestId != autoOpenedAirDropRequestID
        {
            autoOpenedAirDropRequestID = airDrop.requestId
            controller.open()
        } else if let previousAirDrop,
                  previousAirDrop.phase == .offer || airDrop == nil,
                  airDrop?.requestId != previousAirDrop.requestId
                      || airDrop?.phase != previousAirDrop.phase
        {
            controller.close()
        }
    }

    private func makeScene() -> NotchScene {
        if let airDrop = currentAirDrop {
            let leadingWidth = CommaNotchAirDropLeadingSlotView.width(
                for: airDrop.transfer.title,
                minimum: Self.airDropLeadingWidth,
                maximum: Self.airDropMaximumLeadingWidth
            )
            return NotchScene(
                hasActivity: true,
                notificationToken: airDrop.notificationToken,
                compactSideWidth: leadingWidth,
                compactLeadingWidth: leadingWidth,
                compactTrailingWidth: Self.airDropTrailingWidth,
                collapsesVirtualCompactNotchWidth: true,
                compactLeadingSlot: NotchScene.erased {
                    CommaNotchAirDropLeadingSlotView(
                        presentation: airDrop,
                        availableWidth: leadingWidth
                    )
                },
                compactTrailingSlot: NotchScene.erased { Color.clear },
                expandedLeadingSlot: NotchScene.erased { Color.clear },
                expandedTrailingSlot: NotchScene.erased { Color.clear },
                expandedContent: NotchScene.erased {
                    CommaNotchAirDropExpandedView(
                        presentation: airDrop,
                        onDecide: { [weak self] accept in
                            guard let self else { return }
                            self.controller.close()
                            self.emit(
                                type: "action",
                                payload: .init(
                                    action: accept ? "airdrop:accept" : "airdrop:decline",
                                    value: airDrop.transfer.requestId
                                )
                            )
                        }
                    )
                },
                expandedSizing: .fixed(CommaNotchAirDropExpandedView.expandedSurfaceSize())
            )
        }

        if let preview {
            return taskScene(tasks: [preview.task], sideWidth: preview.sideWidth)
        }

        if !currentTasks.isEmpty {
            return taskScene(tasks: currentTasks, sideWidth: compactSideWidth)
        }

        return NotchScene(
            hasActivity: hasActivity,
            notificationToken: notificationSequence,
            compactSideWidth: 78,
            compactLeadingSlot: NotchScene.erased {
                Text(currentTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 78, alignment: .trailing)
            },
            compactTrailingSlot: NotchScene.erased {
                Text(currentSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .frame(maxWidth: 78, alignment: .leading)
            },
            expandedLeadingSlot: NotchScene.erased {
                Text(currentTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            },
            expandedTrailingSlot: NotchScene.erased {
                Text("Electron IPC")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            },
            expandedContent: NotchScene.erased {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentSubtitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(currentDetail)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label("SwiftUI", systemImage: "sparkles")
                        Label("JSONL bridge", systemImage: "arrow.left.arrow.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Control Electron from the notch")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))

                        HStack(spacing: 8) {
                            notchButton("Set text") {
                                self.emit(
                                    type: "action",
                                    payload: .init(
                                        action: "renderer:setBanner",
                                        value: "Updated by a SwiftUI button inside NotchKit"
                                    )
                                )
                            }
                            notchButton("Accent") {
                                self.emit(type: "action", payload: .init(action: "renderer:toggleAccent"))
                            }
                            notchButton("Minimize") {
                                self.emit(type: "action", payload: .init(action: "window:minimize"))
                            }
                            notchButton("Maximize") {
                                self.emit(type: "action", payload: .init(action: "window:toggleMaximize"))
                            }
                            notchButton("Focus") {
                                self.emit(type: "action", payload: .init(action: "window:focus"))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(width: 456, alignment: .leading)
                .padding(.top, 6)
            },
            expandedSizing: .fixed(CGSize(width: 520, height: 250))
        )
    }

    private func taskScene(tasks: [CommaNotchScenePayloadTask], sideWidth: CGFloat) -> NotchScene {
        let leadingWidth = sideWidth
        let trailingWidth = max(Self.compactTrailingMinimumWidth, (sideWidth / 2).rounded())
        return NotchScene(
            hasActivity: true,
            notificationToken: notificationSequence > 0 ? notificationSequence : nil,
            compactSideWidth: leadingWidth,
            compactLeadingWidth: leadingWidth,
            compactTrailingWidth: trailingWidth,
            collapsesVirtualCompactNotchWidth: true,
            compactLeadingSlot: NotchScene.erased {
                CommaNotchActivityLeadingSlotView(
                    tasks: tasks,
                    availableWidth: leadingWidth
                )
            },
            compactTrailingSlot: NotchScene.erased {
                CommaNotchActivityTrailingSlotView(
                    count: tasks.count,
                    availableWidth: trailingWidth
                )
            },
            expandedLeadingSlot: NotchScene.erased { Color.clear },
            expandedTrailingSlot: NotchScene.erased { Color.clear },
            expandedContent: NotchScene.erased {
                CommaNotchTasksView(
                    tasks: tasks,
                    listTitle: listTitle,
                    listSubtitle: listSubtitle,
                    openChatLabel: openChatLabel,
                    onOpen: { [weak self] taskID in
                        guard let self else { return }
                        self.controller.close()
                        self.emit(
                            type: "action",
                            payload: .init(action: "task:open", value: taskID)
                        )
                    }
                )
            },
            expandedSizing: .fixed(
                CommaNotchTasksView.expandedSurfaceSize(taskCount: tasks.count)
            )
        )
    }

    private func notchButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func emit(type: String, id: String? = nil, payload: EventPayload? = nil, error: String? = nil) {
        let event = HostEvent(type: type, id: id, payload: payload, error: error)
        guard let data = try? JSONEncoder().encode(event),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }
}

let host = NotchHost()

NSApplication.shared.setActivationPolicy(.accessory)
host.start()

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        guard let data = line.data(using: .utf8) else { continue }

        do {
            let command = try JSONDecoder().decode(HostCommand.self, from: data)
            DispatchQueue.main.async {
                host.handle(command)
            }
        } catch {
            let message = HostEvent(type: "error", id: nil, payload: nil, error: error.localizedDescription)
            if let data = try? JSONEncoder().encode(message),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
    }

    DispatchQueue.main.async {
        NSApplication.shared.terminate(nil)
    }
}

NSApplication.shared.run()
