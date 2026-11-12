import UIKit

/// Image bytes and message blocks served locally through the production core.
enum ChatImageFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--chat-images") }
    @MainActor private static var failedVideoCover = false

    static var messages: [String] {
        let messages = (0..<3).map { index in
            if index == 0 {
                return #"{"message_id":"photo0","kind":"message","actor_type":"user","content":[{"type":"text","text":"I've attached some files:\n\nAttached files in your workspace:\n- Photo0.png (workspace file: /uploads/abcdefghijklmnopqrstuv-Photo0.png)"}]}"#
            }
            return #"{"message_id":"photo\#(index)","kind":"message","actor_type":"agent","agent_id":"artist","content":[\#(image(index))]}"#
        }
        if ProcessInfo.processInfo.arguments.contains("--chat-video") {
            let name = ProcessInfo.processInfo.arguments.contains("--chat-cover-fails") ? "V5-材质相机灯光验证.mp4" : "clip.mp4"
            let size = (try? Bundle.main.url(forResource: "chat-video", withExtension: "mp4")?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let video = #"{"type":"file","file_name":"\#(name)","mime_type":"video/mp4","blob_ref":{"kind":"blob","uuid":"\#(String(repeating: "0", count: 32))","hash":"\#(String(repeating: "a", count: 64))","size":\#(size)}}"#
            return [messages[0], #"{"message_id":"mixed","kind":"message","actor_type":"agent","agent_id":"artist","content":[\#(image(1)),\#(video),\#(image(2))]}"#]
        }
        guard ProcessInfo.processInfo.arguments.contains("--chat-image-group") else { return messages }
        let images = (1...8).map(image).joined(separator: ",")
        return [messages[0], #"{"message_id":"photo-group","kind":"message","actor_type":"agent","agent_id":"artist","content":[\#(images)]}"#]
    }

    private static func image(_ index: Int) -> String {
        #"{"type":"image","file_name":"Photo\#(index).png","mime_type":"image/png","blob_ref":{"kind":"blob","uuid":"\#(String(repeating: "0", count: 31))\#(index)","hash":"\#(String(repeating: "a", count: 64))","size":100},"width":1200,"height":800}"#
    }

    @MainActor static func response(_ path: String, body: Data?, range: String? = nil) -> FixtureResponse? {
        guard enabled else { return nil }
        if path == "groups/g/conversations/home/messages/mixed/attachments/1",
           let url = Bundle.main.url(forResource: "chat-video", withExtension: "mp4"), let data = try? Data(contentsOf: url) {
            if ProcessInfo.processInfo.arguments.contains("--chat-cover-fails"), !failedVideoCover {
                failedVideoCover = true
                return .json(404, Data(#"{"error":"not_found"}"#.utf8))
            }
            let numbers = range?.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) } ?? []
            let start = min(data.count, numbers.first ?? 0)
            let end = min(data.count, (numbers.count > 1 ? numbers[1] + 1 : data.count))
            return .partial(data.subdata(in: start..<max(start, end)), "video/mp4", offset: start, total: data.count)
        }
        let index: Int
        if path == "groups/g/files" { index = 0 }
        else if path.hasPrefix("groups/g/conversations/home/messages/") {
            let components = path.split(separator: "/")
            guard components.count == 8, components[6] == "attachments", let position = Int(components[7]) else { return nil }
            let message = String(components[5])
            if message == "mixed" { index = position == 0 ? 1 : 2 }
            else if message == "photo-group" { index = position + 1 }
            else if let number = message.last?.wholeNumberValue { index = number }
            else { return nil }
        }
        else if path == "groups/g/agents/artist/resources",
                let json = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                let ref = json["ref"] as? [String: Any], let uuid = ref["uuid"] as? String,
                let number = uuid.last?.wholeNumberValue { index = number }
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).pngData { context in
            [UIColor.systemBlue, .systemOrange, .systemGreen][index % 3].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            ("Photo \(index + 1)" as NSString).draw(at: CGPoint(x: 80, y: 300), withAttributes: [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold), .foregroundColor: UIColor.white,
            ])
        }
        return .bytes(data, "image/png")
    }
}
