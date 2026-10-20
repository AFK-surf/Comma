import CoreMedia
import Foundation
import Speech
import Testing
import QuickChatCore
@testable import QuickChatHost

struct SpeechTimingTests {
    @Test func timeRunsKeepUntimedPunctuationAndContiguousTokens() {
        func timed(_ words: String, _ start: Double, _ end: Double) -> AttributedString {
            var text = AttributedString(words)
            text.audioTimeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1000),
                end: CMTime(seconds: end, preferredTimescale: 1000)
            )
            return text
        }
        let text = AttributedString("...") + timed("Send 123", 0, 2) + AttributedString(".") +
            timed("45", 2, 3) + AttributedString(" to ") + timed("github", 3, 4) +
            AttributedString(".") + timed("com", 4, 5) + AttributedString(". 然后，") +
            timed("完成", 5, 6) + AttributedString("。")
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 6, preferredTimescale: 1000))
        var exact = ExactSpeech(writesCJK: [false])
        for segment in ExactSpeech.Segment.segments(text, range: range) { exact.add(segment, from: 0) }
        #expect(exact.text == "Send 123.45 to github.com. 然后，完成。")
        exact.pause(at: 5)
        exact.hearFromServer("Send 123.45 to github.com.", for: 0..<5)
        #expect(exact.text == "Send 123.45 to github.com. 完成。")
    }
}
