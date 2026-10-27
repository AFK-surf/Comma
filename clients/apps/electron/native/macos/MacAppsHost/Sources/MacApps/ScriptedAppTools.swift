import Foundation
import MCP

// Messages, Mail, Notes and Music: AppleScript through Automation permission.
// Messages history is not read: its database needs Full Disk Access, which
// Comma does not ask for (every command its station runs would share it).

enum MessagesTools {
    static let all: [ToolDefinition] = [send]

    static let send = ToolDefinition(
        app: .messages,
        name: "send",
        title: "Send message",
        description: "Sends an iMessage or SMS from the user's own Apple ID through the Messages app to one phone number or email, `to`. Messages accepting the message does not confirm delivery.",
        inputSchema: Schema.object([
            "to": Schema.string("Phone number or email address of one person."),
            "text": Schema.string("The message."),
            "service": Schema.string("Send as iMessage (default) or SMS.", enum: ["iMessage", "SMS"]),
        ], required: ["to", "text"]),
        readOnly: false,
        openWorld: true,
        requirements: [.automation(BundleID.messages)]
    ) { arguments, context in
        let text = try arguments.requiredString("text")
        let to = try arguments.requiredString("to")
        let service = try arguments.choice("service", ["iMessage", "SMS"], default: "iMessage")
        _ = try await context.appleScript.call(
            Scripts.messages, "send_to_handle", [.text(to), .text(text), .text(service)],
            target: BundleID.messages)
        return ["sent": .bool(true), "to": .string(to), "service": .string(service)]
    }
}

enum MailTools {
    static let all: [ToolDefinition] = [createDraft]

    static let createDraft = ToolDefinition(
        app: .mail,
        name: "create_draft",
        title: "Create email draft",
        description: "Opens a new message in the Mail app with the recipients, subject and body filled in. It is not sent: the user reviews it and clicks Send.",
        inputSchema: Schema.object([
            "to": Schema.strings("Recipient email addresses."),
            "cc": Schema.strings("Cc addresses."),
            "bcc": Schema.strings("Bcc addresses."),
            "subject": Schema.string("Subject."),
            "body": Schema.string("Plain-text body."),
        ], required: ["subject", "body"]),
        readOnly: false,
        requirements: [.automation(BundleID.mail)]
    ) { arguments, context in
        let to = try arguments.strings("to")
        let cc = try arguments.strings("cc")
        let bcc = try arguments.strings("bcc")
        for (field, addresses) in [("to", to), ("cc", cc), ("bcc", bcc)] where addresses.contains(where: { !$0.contains("@") }) {
            throw ToolFailure.invalidArguments(field, "\(field) must contain email addresses.")
        }
        let subject = try arguments.requiredString("subject")
        _ = try await context.appleScript.call(
            Scripts.mail, "compose",
            [.texts(to), .texts(cc), .texts(bcc), .text(subject), .text(arguments.string("body") ?? "")],
            target: BundleID.mail)
        return ["opened": .bool(true), "sent": .bool(false), "subject": .string(subject)]
    }
}

enum NotesTools {
    static let all: [ToolDefinition] = [search, read, create]

    static let search = ToolDefinition(
        app: .notes,
        name: "search",
        title: "Search notes",
        description: "Finds notes in the Notes app whose title or text contains the query. Locked notes are listed but their text cannot be read.",
        inputSchema: Schema.object([
            "query": Schema.string("Text to look for."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 50),
        ], required: ["query"]),
        readOnly: true,
        requirements: [.automation(BundleID.notes)]
    ) { arguments, context in
        let limit = try arguments.limit(default: 20, max: 50)
        let result = try await context.appleScript.call(
            Scripts.notes, "search_notes", [.text(arguments.requiredString("query")), .integer(limit)],
            target: BundleID.notes)
        let notes = result[1].list.map { note -> Value in
            [
                "id": .optional(note[0].text),
                "name": .optional(note[1].text),
                "modified": .optional(note[2].date),
                "locked": .bool(note[3].flag ?? false),
                "folder": .optional(note[4].text),
            ]
        }
        return ["notes": .array(notes), "truncated": .bool(Int(result[0].number ?? 0) > notes.count)]
    }

    static let read = ToolDefinition(
        app: .notes,
        name: "read",
        title: "Read note",
        description: "Reads a note's title and text. A locked note returns locked: true without its text.",
        inputSchema: Schema.object([
            "id": Schema.string("Note id from notes_search."),
        ], required: ["id"]),
        readOnly: true,
        requirements: [.automation(BundleID.notes)]
    ) { arguments, context in
        let note = try await context.appleScript.call(
            Scripts.notes, "read_note", [.text(arguments.requiredString("id"))], target: BundleID.notes)
        let text = note[6].text ?? ""
        return [
            "id": .optional(note[0].text),
            "name": .optional(note[1].text),
            "created": .optional(note[2].date),
            "modified": .optional(note[3].date),
            "folder": .optional(note[4].text),
            "locked": .bool(note[5].flag ?? false),
            "text": .string(truncated(text, 20_000)),
            "truncated": .bool(text.count > 20_000),
        ]
    }

    static let create = ToolDefinition(
        app: .notes,
        name: "create",
        title: "Create note",
        description: "Creates a note. The first line of the note is its title.",
        inputSchema: Schema.object([
            "title": Schema.string("Title."),
            "text": Schema.string("Plain-text body. Line breaks are kept."),
            "folder": Schema.string("Folder name. Defaults to the default folder."),
        ], required: ["title"]),
        readOnly: false,
        requirements: [.automation(BundleID.notes)]
    ) { arguments, context in
        let html = noteHTML(title: try arguments.requiredString("title"), text: try arguments.string("text") ?? "")
        let note = try await context.appleScript.call(
            Scripts.notes, "create_note", [.text(html), .text(arguments.string("folder") ?? "")],
            target: BundleID.notes)
        return ["id": .optional(note[0].text), "name": .optional(note[1].text), "folder": .optional(note[2].text)]
    }

    static func noteHTML(title: String, text: String) -> String {
        func escaped(_ line: String) -> String {
            line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = text.isEmpty ? [] : text.components(separatedBy: .newlines)
        let body = lines.map { $0.isEmpty ? "<div><br></div>" : "<div>\(escaped($0))</div>" }
        return (["<div><h1>\(escaped(title))</h1></div>"] + body).joined()
    }
}

enum MusicTools {
    static let all: [ToolDefinition] = [
        nowPlaying, play, pause, next, previous, setVolume, searchLibrary, playTrack, listPlaylists, playPlaylist,
        setShuffle,
    ]

    private static let target = BundleID.music
    private static let requirements: [Requirement] = [.automation(BundleID.music)]

    static let nowPlaying = ToolDefinition(
        app: .music,
        name: "now_playing",
        title: "Now playing",
        description: "Reports what the Music app is playing, its volume and shuffle state. Does not open Music when it is closed.",
        inputSchema: Schema.object(),
        readOnly: true,
        requirements: requirements
    ) { _, context in
        let info: ScriptValue
        do {
            info = try await context.appleScript.call(Scripts.music, "now_playing", target: target, launch: false)
        } catch let failure as ToolFailure where failure.code == "app_not_running" {
            return ["state": "not_running"]
        }
        var value: [String: Value] = [
            "state": .optional(info[0].text),
            "volume": .int(Int(info[1].number ?? 0)),
            "shuffle": .bool(info[2].flag ?? false),
            "repeat": .optional(info[3].text),
        ]
        if info.list.count > 4 {
            value["track"] = [
                "name": .optional(info[4].text),
                "artist": .optional(info[5].text),
                "album": .optional(info[6].text),
                "duration_seconds": .int(Int(info[7].number ?? 0)),
                "position_seconds": .int(Int(info[8].number ?? 0)),
            ]
        }
        return .object(value)
    }

    private static func control(_ name: String, _ title: String, _ description: String, _ command: String) -> ToolDefinition {
        ToolDefinition(
            app: .music, name: name, title: title, description: description, inputSchema: Schema.object(),
            readOnly: false, requirements: requirements
        ) { _, context in
            let state = try await context.appleScript.call(Scripts.music, "control", [.text(command)], target: target)
            return ["state": .optional(state.text)]
        }
    }

    static let play = control("play", "Play", "Starts or resumes playback in the Music app.", "play")
    static let pause = control("pause", "Pause", "Pauses the Music app.", "pause")
    static let next = control("next", "Next track", "Skips to the next track.", "next")
    static let previous = control("previous", "Previous track", "Goes back to the previous track.", "previous")

    static let setVolume = ToolDefinition(
        app: .music,
        name: "set_volume",
        title: "Set Music volume",
        description: "Sets the Music app's own volume, from 0 to 100. The Mac's volume is system_set_volume.",
        inputSchema: Schema.object([
            "volume": Schema.integer("0 to 100.", minimum: 0, maximum: 100),
        ], required: ["volume"]),
        readOnly: false,
        requirements: requirements
    ) { arguments, context in
        let volume = try arguments.int("volume", in: 0...100) ?? 0
        _ = try await context.appleScript.call(Scripts.music, "set_volume", [.integer(volume)], target: target)
        return ["volume": .int(volume)]
    }

    static let searchLibrary = ToolDefinition(
        app: .music,
        name: "search_library",
        title: "Search Music library",
        description: "Searches songs in the user's Music library by title, artist or album. Songs that are only in the Apple Music catalog are not found.",
        inputSchema: Schema.object([
            "query": Schema.string("Title, artist or album."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 50),
        ], required: ["query"]),
        readOnly: true,
        requirements: requirements
    ) { arguments, context in
        let limit = try arguments.limit(default: 20, max: 50)
        let result = try await context.appleScript.call(
            Scripts.music, "search_library", [.text(arguments.requiredString("query")), .integer(limit)],
            target: target)
        let tracks = result[1].list.map { track -> Value in
            [
                "id": .optional(track[0].text),
                "name": .optional(track[1].text),
                "artist": .optional(track[2].text),
                "album": .optional(track[3].text),
                "duration_seconds": .int(Int(track[4].number ?? 0)),
            ]
        }
        return ["tracks": .array(tracks), "truncated": .bool(Int(result[0].number ?? 0) > tracks.count)]
    }

    static let playTrack = ToolDefinition(
        app: .music,
        name: "play_track",
        title: "Play song",
        description: "Plays a song from the user's library.",
        inputSchema: Schema.object([
            "id": Schema.string("Song id from music_search_library."),
        ], required: ["id"]),
        readOnly: false,
        requirements: requirements
    ) { arguments, context in
        let track = try await context.appleScript.call(
            Scripts.music, "play_track", [.text(arguments.requiredString("id"))], target: target)
        return ["playing": ["name": .optional(track[0].text), "artist": .optional(track[1].text)]]
    }

    static let listPlaylists = ToolDefinition(
        app: .music,
        name: "list_playlists",
        title: "List playlists",
        description: "Lists the user's playlists in the Music app.",
        inputSchema: Schema.object(),
        readOnly: true,
        requirements: requirements
    ) { _, context in
        let lists = try await context.appleScript.call(Scripts.music, "list_playlists", target: target)
        return ["playlists": .array(lists.list.map { list in
            [
                "id": .optional(list[0].text),
                "name": .optional(list[1].text),
                "track_count": .int(Int(list[2].number ?? 0)),
                "smart": .bool(list[3].flag ?? false),
            ]
        })]
    }

    static let playPlaylist = ToolDefinition(
        app: .music,
        name: "play_playlist",
        title: "Play playlist",
        description: "Plays one of the user's playlists.",
        inputSchema: Schema.object([
            "id": Schema.string("Playlist id from music_list_playlists."),
        ], required: ["id"]),
        readOnly: false,
        requirements: requirements
    ) { arguments, context in
        let name = try await context.appleScript.call(
            Scripts.music, "play_playlist", [.text(arguments.requiredString("id"))], target: target)
        return ["playing": .optional(name.text)]
    }

    static let setShuffle = ToolDefinition(
        app: .music,
        name: "set_shuffle",
        title: "Shuffle",
        description: "Turns shuffle on or off in the Music app.",
        inputSchema: Schema.object([
            "enabled": Schema.boolean("true to shuffle."),
        ], required: ["enabled"]),
        readOnly: false,
        requirements: requirements
    ) { arguments, context in
        guard let enabled = try arguments.bool("enabled") else {
            throw ToolFailure.invalidArguments("enabled", "enabled is required.")
        }
        _ = try await context.appleScript.call(Scripts.music, "set_shuffle", [.flag(enabled)], target: target)
        return ["shuffle": .bool(enabled)]
    }
}
