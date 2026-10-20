/// When the person pauses: the microphone has stayed near the room's noise
/// floor for `length` after speech. Neither transcriber finalizes there on
/// its own soon enough: the exact one waits for about 12 s of audio, the
/// live one for 2 to 3 s of quiet. Cutting there splits no word.
///
/// The floor follows the quietest sound and rises slowly, so a fan or a
/// room's hum becomes the floor, and the gaps between syllables keep it
/// down while the person talks.
public struct SpeechPause: Sendable {
    /// Shorter than the quiet after a sentence, longer than most within one.
    static let length = 0.6
    /// Speech is this much louder than the floor, in dB.
    static let speech = 12.0
    /// How fast the floor rises toward louder sound, in dB a second.
    static let floorRise = 2.0

    private var floor: Double?
    private var spoke = false
    private var quiet = 0.0

    public init() {}

    /// One buffer of `seconds` of audio, `decibels` loud (RMS, dBFS). True for
    /// the buffer that completes a pause; once for each pause.
    public mutating func hear(decibels: Double, seconds: Double) -> Bool {
        let floor = min(decibels, (self.floor ?? decibels) + Self.floorRise * seconds)
        self.floor = floor
        if decibels > floor + Self.speech {
            spoke = true
            quiet = 0
            return false
        }
        quiet += seconds
        guard spoke, quiet >= Self.length else { return false }
        spoke = false
        return true
    }
}
