package surf.comma.android.settings.devices

/**
 * The `client_source` values of the boards Comma firmware runs on, as the Hardware repo defines
 * them (firmware/main/Kconfig.projbuild): LilyGO T-Circle-S3, M5Stack StickS3, Waveshare
 * ESP32-S3-Touch-AMOLED-1.32, and ESP32 DevKit.
 */
internal object CommaBoards {
    val clientSources: Set<String> = setOf("t-circle", "m5stack-sticks3", "waveshare-amoled-1-32", "esp32-devkit")
}
