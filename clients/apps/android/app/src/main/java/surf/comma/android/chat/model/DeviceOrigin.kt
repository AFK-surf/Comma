package surf.comma.android.chat.model

/**
 * Which kind of device said something: a label on a conversation and on a message, never a rule.
 *
 * The phone and the Mac are both connectors to the same conversation. Where a message came from
 * changes the small picture next to it and nothing else -- not how it renders, not whether it is
 * shown, not what the phone does with the turn.
 */
enum class DeviceOrigin(val wire: String) {
    PHONE("phone"),
    MAC("mac"),
    ;

    companion object {
        /** What this build runs on. A message from a device of this kind carries no mark. */
        val LOCAL = PHONE

        /** A kind this build has a picture for, or null. */
        fun fromWire(kind: String?): DeviceOrigin? = entries.firstOrNull { it.wire == kind }

        /**
         * The pictures in front of a conversation's title: one per known kind, phone before Mac
         * whatever order Core listed them in. No kinds, no pictures.
         */
        fun iconsFor(kinds: List<String>): List<DeviceOrigin> {
            val known = kinds.mapNotNullTo(HashSet(), ::fromWire)
            return entries.filter { it in known }
        }

        /**
         * The mark on a message: a user message another kind of device sent. This phone's own
         * messages, answers, and messages whose device Core did not name carry none.
         */
        fun markFor(message: ChatMessage): DeviceOrigin? {
            if (message.role != ChatRole.USER) return null
            return fromWire(message.originKind)?.takeIf { it != LOCAL }
        }
    }
}
