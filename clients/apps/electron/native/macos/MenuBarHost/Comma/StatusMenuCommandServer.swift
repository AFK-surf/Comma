import AppKit
import Foundation

/// The transport between Electron Main and the menu-bar helper: generated
/// newline-delimited frames on stdin and stdout, diagnostics on stderr. The
/// helper draws the menu-bar item that `status-menu.show` describes, reports a
/// chosen row as `status-menu.select`, and ends when its input closes.
@MainActor
final class StatusMenuCommandServer {
    private var readTask: Task<Void, Never>?
    private lazy var statusMenu = StatusMenuController { [weak self] id in
        self?.emit(.select(requestId: UUID().uuidString, id: id))
    }

    func start() {
        guard readTask == nil else { return }

        emit(.ready(requestId: UUID().uuidString))
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let line = readLine() else {
                    guard !Task.isCancelled else { return }
                    await self?.parentInputDidClose()
                    return
                }
                guard let data = line.data(using: .utf8) else {
                    await self?.emitProtocolError(
                        error: "Menu-bar frame is not valid UTF-8.",
                        frameKind: nil,
                        receivedProtocolVersion: nil
                    )
                    continue
                }

                do {
                    let frame = try JSONDecoder().decode(CommaStatusMenuHostFrame.self, from: data)
                    await self?.handle(frame)
                } catch {
                    let metadata = frameMetadata(data)
                    await self?.emitProtocolError(
                        error: "Menu-bar protocol version or frame validation failed: \(error.localizedDescription)",
                        frameKind: metadata.kind,
                        receivedProtocolVersion: metadata.protocolVersion
                    )
                }
            }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        statusMenu.hide()
    }

    private func parentInputDidClose() {
        guard readTask != nil else { return }
        NSApp.terminate(nil)
    }

    private func handle(_ frame: CommaStatusMenuHostFrame) {
        switch frame {
        case let .show(requestId, closeId, iconPath, openId, rows, toolTip, width):
            statusMenu.show(
                iconPath: iconPath, toolTip: toolTip, rows: rows, width: width,
                openId: openId, closeId: closeId
            )
            emit(.result(requestId: requestId, error: nil, ok: true))
        case let .hide(requestId):
            statusMenu.hide()
            emit(.result(requestId: requestId, error: nil, ok: true))
        }
    }

    private func emitProtocolError(
        error: String,
        frameKind: String?,
        receivedProtocolVersion: Int?
    ) {
        emit(.protocolError(
            error: error,
            frameKind: frameKind,
            receivedProtocolVersion: receivedProtocolVersion
        ))
    }

    private func emit(_ frame: CommaStatusMenuClientFrame) {
        do {
            let data = try JSONEncoder().encode(frame)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            let line = "[CommaMenuBarHost] Failed to encode generated frame: \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

private func frameMetadata(_ data: Data) -> (kind: String?, protocolVersion: Int?) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (nil, nil)
    }
    return (
        object["kind"] as? String,
        (object["protocolVersion"] as? NSNumber)?.intValue
    )
}
