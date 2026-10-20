package surf.comma.android.chat.render

/**
 * The transform one EXIF orientation asks for: a rotation, then a mirror.
 *
 * Order matters and is fixed here rather than at each call site — rotate then
 * mirror and mirror then rotate differ for 5 and 7, which are exactly the two
 * nobody has a test image for.
 */
internal data class OrientationTransform(
    val rotationDegrees: Int,
    val mirrored: Boolean,
) {
    val isIdentity: Boolean get() = rotationDegrees == 0 && !mirrored

    /** True when the transform exchanges width and height. */
    val swapsAxes: Boolean get() = rotationDegrees == 90 || rotationDegrees == 270
}

/**
 * EXIF orientation, as arithmetic.
 *
 * Kept away from `android.graphics` on purpose. The decision — which rotation,
 * mirrored or not, and therefore what size the result is — is the part that can
 * be wrong in a way nobody notices until a screenshot arrives sideways, and it
 * is the part a JVM test can actually check. Applying the resulting matrix to a
 * bitmap is eight lines with nothing to decide.
 */
internal object MediaOrientation {

    /** Anything outside 1–8, including a value Core could not read, means upright. */
    fun transformFor(orientation: Int): OrientationTransform = when (orientation) {
        2 -> OrientationTransform(0, mirrored = true)
        3 -> OrientationTransform(180, mirrored = false)
        4 -> OrientationTransform(180, mirrored = true)
        5 -> OrientationTransform(90, mirrored = true)
        6 -> OrientationTransform(90, mirrored = false)
        7 -> OrientationTransform(270, mirrored = true)
        8 -> OrientationTransform(270, mirrored = false)
        else -> OrientationTransform(0, mirrored = false)
    }

    /**
     * The size the original *displays* at, from the size it is stored at.
     *
     * This is the client's half of the agreement `shared/media.md` describes:
     * Core reports `width`/`height` after applying the very same orientation, so
     * running this over a decoded original must land on the numbers the message
     * already reserved layout space with. When it does not, the picture and the
     * hole cut for it face different ways.
     */
    fun displayedSize(rawWidth: Int, rawHeight: Int, orientation: Int): Pair<Int, Int> =
        if (transformFor(orientation).swapsAxes) rawHeight to rawWidth else rawWidth to rawHeight
}
