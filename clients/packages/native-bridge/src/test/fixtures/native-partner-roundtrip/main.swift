import Foundation

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()

func expectDecodeFailure<Value: Decodable>(
    _ type: Value.Type,
    json: String,
    label: String
) {
    if let _ = try? decoder.decode(type, from: Data(json.utf8)) {
        fatalError("\(label) unexpectedly decoded")
    }
}

let menu = CommaStatusMenuHostFrame.show(
    requestId: "request-1",
    clickId: "status-item:click",
    closeId: nil,
    iconPath: "/resources/CommaTemplate.png",
    openId: nil,
    rows: [
        CommaStatusMenuShowRow(id: "open-comma", kind: .item, shortcut: "⌥ Space", title: "Open Comma"),
        CommaStatusMenuShowRow(kind: .separator),
        CommaStatusMenuShowRow(detail: "40% · resets in 2h", fraction: 0.4, kind: .meter, title: "5-hour", tone: .normal),
    ],
    toolTip: "Comma is running",
    width: 260
)
let menuData = try encoder.encode(menu)
let menuObject = try JSONSerialization.jsonObject(with: menuData) as? [String: Any]
precondition(menuObject?["kind"] as? String == "status-menu.show")
precondition(menuObject?["protocolVersion"] as? Int == 3)
precondition(menuObject?["closeId"] == nil)
let decodedMenu = try decoder.decode(CommaStatusMenuHostFrame.self, from: menuData)
precondition(decodedMenu == menu)

let select = try decoder.decode(
    CommaStatusMenuClientFrame.self,
    from: Data(#"{"id":"open-comma","kind":"status-menu.select","protocolVersion":3,"requestId":"select-1"}"#.utf8)
)
precondition(select == .select(requestId: "select-1", id: "open-comma"))

let additiveFrame = try decoder.decode(
    CommaStatusMenuHostFrame.self,
    from: Data(#"{"kind":"status-menu.hide","protocolVersion":3,"requestId":"request-additive","unexpected":true}"#.utf8)
)
let additiveRoundTripObject = try JSONSerialization.jsonObject(
    with: try encoder.encode(additiveFrame)
) as? [String: Any]
precondition(additiveRoundTripObject?["unexpected"] == nil)

let protocolError = CommaStatusMenuClientFrame.protocolError(
    error: "Unsupported protocol version",
    frameKind: "status-menu.hide",
    receivedProtocolVersion: 2
)
let decodedProtocolError = try decoder.decode(
    CommaStatusMenuClientFrame.self,
    from: try encoder.encode(protocolError)
)
precondition(decodedProtocolError == protocolError)

do {
    _ = try decoder.decode(
        CommaStatusMenuHostFrame.self,
        from: Data(#"{"kind":"status-menu.hide","protocolVersion":1,"requestId":"request-2"}"#.utf8)
    )
    fatalError("version mismatch unexpectedly decoded")
} catch DecodingError.dataCorrupted {
    // Expected: CommaChatProtocolVersion only admits the generated current version.
}

expectDecodeFailure(
    CommaStatusMenuHostFrame.self,
    json: #"{"kind":"status-menu.hide","protocolVersion":3,"requestId":""}"#,
    label: "empty requestId"
)
expectDecodeFailure(
    CommaStatusMenuClientFrame.self,
    json: #"{"error":"Unsupported protocol version","expectedProtocolVersion":3,"frameKind":null,"kind":"status-menu.protocol-error","protocolVersion":3}"#,
    label: "explicit null optional field"
)
expectDecodeFailure(
    CommaStatusMenuHostFrame.self,
    json: #"{"iconPath":"/icon.png","kind":"status-menu.show","protocolVersion":3,"requestId":"narrow","rows":[],"toolTip":"Comma","width":119}"#,
    label: "menu narrower than its minimum"
)

let invalidCommand = CommaStatusMenuHostFrame.hide(requestId: "")
if (try? encoder.encode(invalidCommand)) != nil {
    fatalError("invalid generated frame unexpectedly encoded")
}

let notch = CommaNotchScenePayload(
    detail: "Generated contract",
    hasActivity: true,
    tasks: [
        CommaNotchScenePayloadTask(
            conversationId: "conversation-1",
            groupId: "group-1",
            id: "task-1",
            status: .inProgress,
            subtitle: "In progress",
            title: "Ship the Notch",
            updatedAt: 1_787_563_200,
            workspaceId: "workspace-1"
        ),
    ],
    title: "Comma"
)
let notchData = try encoder.encode(notch)
let decodedNotch = try decoder.decode(CommaNotchScenePayload.self, from: notchData)
precondition(decodedNotch == notch)

print("native partner Codable round-trip passed")
