/// The AppleScript handlers the tools call. Arguments arrive as handler
/// parameters; nothing from a tool call is spliced into these sources.
enum Scripts {
    static let all: [String] = [messages, mail, notes, music, systemEvents]

    static let messages = """
        on send_to_handle(handleId, messageText, serviceKind)
            tell application "Messages"
                with timeout of 15 seconds
                    if serviceKind is "SMS" then
                        set targetService to 1st account whose service type = SMS
                    else
                        set targetService to 1st account whose service type = iMessage
                    end if
                    send messageText to participant handleId of targetService
                end timeout
            end tell
            return true
        end send_to_handle

        """

    static let mail = """
        on compose(toList, ccList, bccList, subjectText, bodyText)
            tell application "Mail"
                with timeout of 15 seconds
                    set draft to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:true}
                    tell draft
                        repeat with anAddress in toList
                            make new to recipient at end of to recipients with properties {address:(anAddress as text)}
                        end repeat
                        repeat with anAddress in ccList
                            make new cc recipient at end of cc recipients with properties {address:(anAddress as text)}
                        end repeat
                        repeat with anAddress in bccList
                            make new bcc recipient at end of bcc recipients with properties {address:(anAddress as text)}
                        end repeat
                    end tell
                    activate
                end timeout
            end tell
            return true
        end compose
        """

    static let notes = """
        on search_notes(queryText, maxCount)
            set results to {}
            tell application "Notes"
                with timeout of 15 seconds
                    set found to (every note whose name contains queryText or plaintext contains queryText)
                    set total to count of found
                    if total > maxCount then set found to items 1 thru maxCount of found
                    repeat with aNote in found
                        set end of results to {id of aNote, name of aNote, modification date of aNote, password protected of aNote, name of container of aNote}
                    end repeat
                end timeout
            end tell
            return {total, results}
        end search_notes

        on read_note(noteId)
            tell application "Notes"
                with timeout of 15 seconds
                    set aNote to note id noteId
                    set locked to password protected of aNote
                    if locked then
                        set bodyText to ""
                    else
                        set bodyText to plaintext of aNote
                    end if
                    return {id of aNote, name of aNote, creation date of aNote, modification date of aNote, name of container of aNote, locked, bodyText}
                end timeout
            end tell
        end read_note

        on create_note(htmlBody, folderName)
            tell application "Notes"
                with timeout of 15 seconds
                    if folderName is "" then
                        set aNote to make new note with properties {body:htmlBody}
                    else
                        set aNote to make new note at folder folderName with properties {body:htmlBody}
                    end if
                    return {id of aNote, name of aNote, name of container of aNote}
                end timeout
            end tell
        end create_note
        """

    static let music = """
        on now_playing()
            tell application "Music"
                set playerState to player state as text
                set info to {playerState, sound volume, shuffle enabled, song repeat as text}
                if playerState is "stopped" then return info
                set aTrack to current track
                return info & {name of aTrack, artist of aTrack, album of aTrack, duration of aTrack, player position}
            end tell
        end now_playing

        on control(command)
            tell application "Music"
                with timeout of 10 seconds
                    if command is "play" then
                        play
                    else if command is "pause" then
                        pause
                    else if command is "next" then
                        next track
                    else if command is "previous" then
                        previous track
                    end if
                    return player state as text
                end timeout
            end tell
        end control

        on set_volume(level)
            tell application "Music" to set sound volume to level
            return level
        end set_volume

        on set_shuffle(enabled)
            tell application "Music" to set shuffle enabled to enabled
            return enabled
        end set_shuffle

        on search_library(queryText, maxCount)
            set results to {}
            tell application "Music"
                with timeout of 15 seconds
                    set found to search library playlist 1 for queryText
                    set total to count of found
                    if total > maxCount then set found to items 1 thru maxCount of found
                    repeat with aTrack in found
                        set end of results to {persistent ID of aTrack, name of aTrack, artist of aTrack, album of aTrack, duration of aTrack}
                    end repeat
                end timeout
            end tell
            return {total, results}
        end search_library

        on play_track(trackId)
            tell application "Music"
                with timeout of 10 seconds
                    set aTrack to first track of library playlist 1 whose persistent ID is trackId
                    play aTrack
                    return {name of aTrack, artist of aTrack}
                end timeout
            end tell
        end play_track

        on list_playlists()
            set results to {}
            tell application "Music"
                with timeout of 15 seconds
                    repeat with aList in (every user playlist)
                        set end of results to {persistent ID of aList, name of aList, count of tracks of aList, smart of aList}
                    end repeat
                end timeout
            end tell
            return results
        end list_playlists

        on play_playlist(playlistId)
            tell application "Music"
                with timeout of 10 seconds
                    set aList to first user playlist whose persistent ID is playlistId
                    play aList
                    return name of aList
                end timeout
            end tell
        end play_playlist
        """

    static let systemEvents = """
        on set_dark_mode(enabled)
            tell application "System Events"
                tell appearance preferences to set dark mode to enabled
            end tell
            return enabled
        end set_dark_mode
        """
}
