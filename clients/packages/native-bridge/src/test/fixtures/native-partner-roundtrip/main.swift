import Foundation

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()

let linkedMessageData = Data(
    #"{"attachments":[],"delivery":"sent","messageId":"reply","platformSource":"telegram","refs":[],"replyToMessageId":"source","threadRootMessageId":"root","role":"assistant","source":"server","text":"Reply"}"#.utf8
)
let linkedMessage = try decoder.decode(CommaChatMessage.self, from: linkedMessageData)
precondition(linkedMessage.replyToMessageId == "source")
precondition(linkedMessage.threadRootMessageId == "root")
precondition(linkedMessage.platformSource == "telegram")
let linkedMessageRoundTrip = try decoder.decode(CommaChatMessage.self, from: encoder.encode(linkedMessage))
precondition(linkedMessageRoundTrip == linkedMessage)

func expectDecodeFailure<Value: Decodable>(
    _ type: Value.Type,
    json: String,
    label: String
) {
    if let _ = try? decoder.decode(type, from: Data(json.utf8)) {
        fatalError("\(label) unexpectedly decoded")
    }
}

let command = CommaSideChatCommand.send(
    workspaceId: "workspace-1",
    conversationId: "conversation-1",
    requestId: "request-1",
    consumeDraft: false,
    groupId: "group-1",
    replyToMessageId: "message-parent",
    sendIntentId: "intent-fixture-0001",
    sessionEpoch: 1,
    skills: nil,
    surfaceId: "native-side-chat",
    text: "Hello"
)
let commandData = try encoder.encode(command)
let commandObject = try JSONSerialization.jsonObject(with: commandData) as? [String: Any]
precondition(commandObject?["kind"] as? String == "chat.send")
precondition(commandObject?["protocolVersion"] as? Int == 3)
precondition(commandObject?["replyToMessageId"] as? String == "message-parent")
let decodedCommand = try decoder.decode(CommaSideChatCommand.self, from: commandData)
precondition(decodedCommand == command)

let resultData = Data(
    #"{"kind":"command.result","ok":true,"protocolVersion":3,"requestId":"request-1"}"#.utf8
)
_ = try decoder.decode(CommaSideChatHostFrame.self, from: resultData)
_ = try decoder.decode(CommaSideChatClientFrame.self, from: resultData)

let additiveData = Data(
    #"{"kind":"side-chat.close","protocolVersion":3,"requestId":"request-additive","unexpected":true}"#.utf8
)
let additiveFrame = try decoder.decode(CommaSideChatHostFrame.self, from: additiveData)
let additiveRoundTripData = try encoder.encode(additiveFrame)
let additiveRoundTripObject = try JSONSerialization.jsonObject(
    with: additiveRoundTripData
) as? [String: Any]
precondition(additiveRoundTripObject?["unexpected"] == nil)

let protocolError = CommaSideChatClientFrame.protocolError(
    error: "Unsupported protocol version",
    frameKind: "side-chat.open",
    receivedProtocolVersion: 2
)
let protocolErrorData = try encoder.encode(protocolError)
let decodedProtocolError = try decoder.decode(
    CommaSideChatClientFrame.self,
    from: protocolErrorData
)
precondition(decodedProtocolError == protocolError)

let wrongVersionData = Data(
    #"{"kind":"side-chat.open","protocolVersion":1,"requestId":"request-2"}"#.utf8
)
do {
    _ = try decoder.decode(CommaSideChatHostFrame.self, from: wrongVersionData)
    fatalError("version mismatch unexpectedly decoded")
} catch DecodingError.dataCorrupted {
    // Expected: CommaChatProtocolVersion only admits the generated current version.
}

expectDecodeFailure(
    CommaSideChatHostFrame.self,
    json: #"{"kind":"side-chat.open","protocolVersion":3,"requestId":""}"#,
    label: "empty requestId"
)
expectDecodeFailure(
    CommaSideChatClientFrame.self,
    json: #"{"error":"Unsupported protocol version","expectedProtocolVersion":3,"frameKind":null,"kind":"side-chat.protocol-error","protocolVersion":3}"#,
    label: "explicit null optional field"
)
expectDecodeFailure(
    CommaSideChatHostFrame.self,
    json: #"{"kind":"chat.snapshot","protocolVersion":3,"snapshot":{"protocolVersion":3,"revision":-1,"sessionEpoch":0,"status":"signed-out"}}"#,
    label: "negative revision"
)
expectDecodeFailure(
    CommaSideChatClientFrame.self,
    json: #"{"conversationId":"conversation-1","groupId":"group-1","kind":"chat.send","protocolVersion":3,"requestId":"request-without-epoch","surfaceId":"native-side-chat","text":"Hello","workspaceId":"workspace-1"}"#,
    label: "missing command sessionEpoch"
)
expectDecodeFailure(
    CommaSideChatClientFrame.self,
    json: #"{"conversationId":"conversation-1","groupId":"group-1","kind":"chat.send","protocolVersion":3,"requestId":"request-negative-epoch","sessionEpoch":-1,"surfaceId":"native-side-chat","text":"Hello","workspaceId":"workspace-1"}"#,
    label: "negative command sessionEpoch"
)

let oversizedMessages: [[String: Any]] = (0..<201).map { index in
    [
        "attachments": [],
        "delivery": "sent",
        "messageId": "message-\(index)",
        "refs": [],
        "role": "assistant",
        "source": "server",
        "text": "message \(index)",
    ]
}
let oversizedSnapshot: [String: Any] = [
    "kind": "chat.snapshot",
    "protocolVersion": 3,
    "snapshot": [
        "protocolVersion": 3,
        "revision": 1,
        "session": [
            "conversationId": "conversation-1",
            "groupId": "group-1",
            "revision": 1,
            "state": [
                "awaitingReply": false,
                "messages": oversizedMessages,
            ],
            "workspaceId": "workspace-1",
        ],
        "sessionEpoch": 1,
        "status": "ready",
    ],
]
let oversizedSnapshotData = try JSONSerialization.data(withJSONObject: oversizedSnapshot)
if let _ = try? decoder.decode(CommaSideChatHostFrame.self, from: oversizedSnapshotData) {
    fatalError("oversized side-chat message window unexpectedly decoded")
}

let invalidCommand = CommaSideChatHostFrame.open(requestId: "")
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
