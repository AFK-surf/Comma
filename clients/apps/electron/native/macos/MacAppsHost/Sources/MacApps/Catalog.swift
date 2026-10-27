/// Every tool, grouped by app in the order the Plugins page lists the apps.
public enum Catalog {
    public static let all: [ToolDefinition] =
        CalendarTools.all + RemindersTools.all + ContactsTools.all + MessagesTools.all + MailTools.all
        + NotesTools.all + MusicTools.all + MapsTools.all + SystemTools.all + VisionTools.all
}
