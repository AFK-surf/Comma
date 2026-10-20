package surf.comma.android.auth

/** The backend accepts exactly six ASCII digits. */
internal object CodeText {
    const val LENGTH = 6

    // A standalone code, optionally split in the middle ("123 456", "123-456").
    private val standalone = Regex("(?<![0-9])([0-9]{3})[ -]?([0-9]{3})(?![0-9])")

    fun digits(raw: CharSequence): String = buildString {
        for (c in raw) if (c in '0'..'9') append(c)
    }

    /** Typed or committed text: keep the digits, up to six. */
    fun normalize(raw: CharSequence): String = digits(raw).take(LENGTH)

    /**
     * Text arriving in one piece (paste, autofill, keyboard suggestion). A message such as
     * "Your code is 123 456, valid for 10 minutes" yields the code, not the first six digits.
     */
    fun extract(raw: CharSequence): String {
        standalone.find(raw)?.let { return it.groupValues[1] + it.groupValues[2] }
        return normalize(raw)
    }
}
