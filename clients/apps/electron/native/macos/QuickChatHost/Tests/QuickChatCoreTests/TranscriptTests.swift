import CoreGraphics
import Testing
@testable import QuickChatCore

struct SpeechTextTests {
    @Test func volatileTextIsReplacedAndFinalTextIsKept() {
        var speech = SpeechText()
        speech.apply("帮我", isFinal: false)
        speech.apply("帮我整理", isFinal: false)
        #expect(speech.text == "帮我整理")
        speech.apply("帮我整理一下", isFinal: true)
        speech.apply("今天", isFinal: false)
        #expect(speech.text == "帮我整理一下今天")
    }

    @Test func chineseIsSpacedAsCommaWritesIt() {
        // One space between Chinese and a Latin word or digit, none inside Chinese.
        for (heard, written) in [
            ("整理成一个任务清单 ，然后发给 worker处理。", "整理成一个任务清单，然后发给 worker 处理。"),
            ("用Comma整理 10月的meeting notes。 Then", "用 Comma 整理 10 月的 meeting notes。Then"),
            ("Summarize the thread.查一下日程", "Summarize the thread. 查一下日程"),
        ] {
            var speech = SpeechText()
            speech.apply(heard, isFinal: true)
            #expect(speech.text == written)
        }
    }

    @Test func latinSegmentsKeepOneSpace() {
        var speech = SpeechText()
        speech.apply("Draft the reply", isFinal: true)
        speech.apply("and send it", isFinal: false)
        #expect(speech.text == "Draft the reply and send it")
        // A sentence's end before the next one, but not inside one.
        speech.apply("and send it.", isFinal: true)
        speech.apply("Then check github.com", isFinal: false)
        #expect(speech.text == "Draft the reply and send it. Then check github.com")
    }

    @Test func aDraftContinues() {
        var speech = SpeechText(draft: "帮我订周五的会议室")
        speech.apply("下午三点", isFinal: false)
        #expect(speech.text == "帮我订周五的会议室下午三点")
        var english = SpeechText(draft: "Book the room")
        english.apply("for Friday", isFinal: true)
        #expect(english.text == "Book the room for Friday")
    }

    @Test func editedWordsStayAsTyped() {
        // The recognizer's spacing rules apply to speech only.
        var speech = SpeechText(draft: "把 Figma  稿子 review")
        #expect(speech.text == "把 Figma  稿子 review")
        speech.apply("一下 ，然后", isFinal: true)
        #expect(speech.spoken == "一下，然后")
        #expect(speech.text == "把 Figma  稿子 review 一下，然后")
    }

    @Test func fillersAreLeftOut() {
        let heard = [
            "帮我看一下明天的日程，然后呃看一下明天下午 4:30 的火车票": "帮我看一下明天的日程，然后看一下明天下午 4:30 的火车票",
            "嗯，然后，呃，把金额改一下，额度不变，好啊，嗯。": "然后，把金额改一下，额度不变，好啊。",
            "额，啊，Um, can you uh check the ER schedule": "can you check the ER schedule",
        ]
        for (said, written) in heard {
            var speech = SpeechText()
            speech.apply(said, isFinal: true)
            #expect(speech.text == written)
        }
    }
}

struct SpeechPauseTests {
    /// Plays 20 ms buffers: (decibels, seconds) runs, and returns the times pauses completed.
    private func pauses(_ runs: [(Double, Double)]) -> [Double] {
        var pause = SpeechPause()
        var time = 0.0
        var found: [Double] = []
        for (decibels, seconds) in runs {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                time += 0.02
                if pause.hear(decibels: decibels, seconds: 0.02) { found.append((time * 100).rounded() / 100) }
            }
        }
        return found
    }

    @Test func aPauseIsQuietAfterSpeech() {
        // Room noise at -60 dB, words at -30 dB with short gaps.
        #expect(pauses([
            (-60, 1), (-30, 0.5), (-58, 0.3), (-30, 1), (-60, 0.8), (-30, 0.5), (-60, 2),
        ]) == [3.4, 4.7])
    }

    @Test func steadyNoiseIsNotSpeech() {
        #expect(pauses([(-42, 6)]).isEmpty)
        // A fan that starts sounds like speech until the floor has risen to it.
        #expect(pauses([(-60, 1), (-42, 5)]) == [4.6])
    }
}

struct ExactSpeechTests {
    private func segment(_ text: String, _ start: Double, _ end: Double, _ confidence: Double) -> ExactSpeech.Segment {
        .init(start: start, end: end, text: text, confidences: [confidence, confidence])
    }

    @Test func eachSentenceIsInTheLanguageItWasSpokenIn() {
        // zh-CN, then en-US.
        var speech = ExactSpeech(writesCJK: [true, false])
        #expect(speech.text == nil)
        speech.add(segment("Driver reply saying I will revew the proposal tonight。", 0, 3.8, 0.86), from: 0)
        speech.add(segment("... Draft a reply saying I will review the proposal tonight.", 0, 3.8, 0.81), from: 1)
        speech.pause(at: 4)
        speech.add(segment("查一下最近三天有哪些任务还没有完成。", 4, 8.9, 0.98), from: 0)
        speech.add(segment("Cha yi xia zui jin san tian.", 4, 8.9, 0.14), from: 1)
        speech.pause(at: 9)
        speech.add(segment("把 Figma里的 onboarding设计稿 review一下。", 9, 12.6, 0.9), from: 0)
        speech.add(segment(", , ...", 9, 12.6, 0.5), from: 1)
        #expect(speech.text(through: 4) == "Draft a reply saying I will review the proposal tonight.")
        #expect(speech.text == "Draft a reply saying I will review the proposal tonight. 查一下最近三天有哪些任务还没有完成。把 Figma 里的 onboarding 设计稿 review 一下。")
    }

    @Test func theServersWordsStandForTheirClip() {
        var speech = ExactSpeech(writesCJK: [true])
        speech.add(segment("帮我看一下明天的日程。", 0, 3, 0.9), from: 0)
        speech.pause(at: 3.1)
        speech.add(segment("然后。", 3.1, 4.5, 0.6), from: 0)
        speech.pause(at: 4.6)
        speech.add(segment("看一下下午的机票。", 4.6, 9, 0.9), from: 0)
        speech.hearFromServer("帮我看一下明天的日程，然后，呃，", for: 0..<4.6)
        #expect(speech.text == "帮我看一下明天的日程，然后，看一下下午的机票。")
        speech.pause(at: 9.2)
        speech.hearFromServer("看一下下午的机票。", for: 4.6..<9.2)
        #expect(speech.text == "帮我看一下明天的日程，然后，看一下下午的机票。")
        // An answer without words changes nothing.
        speech.hearFromServer(" ", for: 4.6..<9.2)
        #expect(speech.text == "帮我看一下明天的日程，然后，看一下下午的机票。")
    }

    @Test func aLongClipPrefersACompletedBoundarySharedByBothLanguages() {
        var speech = ExactSpeech(writesCJK: [false, true])
        speech.add(segment("last words", 48, 55, 0.9), from: 0)
        speech.add(segment("末尾", 48, 55, 0.9), from: 1)
        #expect(speech.checkpoint(after: 0, through: 60) == 55)
        // A second language's already-final sentence can span the other's end.
        speech.add(segment("下一句话", 55, 62, 0.9), from: 1)
        speech.add(segment("next", 55, 58, 0.9), from: 0)
        #expect(speech.checkpoint(after: 0, through: 60) == 55)
        #expect(speech.checkpoint(after: 55, through: 115) == 115)
    }

    @Test func aLaterClipsWordsKeepTheEarlierOnes() {
        var speech = ExactSpeech(writesCJK: [false])
        speech.add(segment("Draft a reply.", 0, 3, 0.8), from: 0)
        speech.pause(at: 3.1)
        speech.add(segment("Then book the room.", 3.1, 6, 0.8), from: 0)
        speech.pause(at: 6.1)
        speech.add(segment("and send it", 6.1, 9, 0.8), from: 0)
        // Two clips are out at once; the second answers first and replaces only its own stretch.
        speech.hearFromServer("Then book the room, please.", for: 3.1..<6.1)
        #expect(speech.text == "Draft a reply. Then book the room, please. and send it")
        speech.hearFromServer("Draft a reply to Pat.", for: 0..<3.1)
        #expect(speech.text == "Draft a reply to Pat. Then book the room, please. and send it")
        #expect(speech.text(through: 3.1) == "Draft a reply to Pat.")
    }
}

struct TranscriptFitTests {
    /// Text whose height is `lines(size)` lines of `size × 1.3`.
    private func fit(height: CGFloat, lines: @escaping (CGFloat) -> CGFloat) -> TranscriptFit.Result {
        TranscriptFit.fit(height: height, maximum: 30, minimum: 17) { size in lines(size) * size * 1.3 }
    }

    @Test func shortTextStaysLargest() {
        #expect(fit(height: 117) { _ in 1 } == .init(fontSize: 30, overflow: 0))
    }

    @Test func longerTextShrinksToTheLargestSizeThatFits() {
        // 120 characters, about 720 / size per line.
        let result = fit(height: 117) { size in (120 / (720 / size)).rounded(.up) }
        #expect(result.overflow == 0)
        #expect(result.fontSize < 30 && result.fontSize >= 17)
        let next = result.fontSize + 0.5
        #expect((120 / (720 / next)).rounded(.up) * next * 1.3 > 117)
    }

    @Test func textBeyondTheSmallestSizeScrolls() {
        let result = fit(height: 117) { _ in 12 }
        #expect(result.fontSize == 17)
        #expect(result.overflow == 12 * 17 * 1.3 - 117)
    }
}

struct TranscriptScrollTests {
    @Test func itFollowsTheLastLine() {
        var scroll = TranscriptScroll()
        scroll.setOverflow(7)
        scroll.setOverflow(27)
        #expect(scroll.offset == 0)
        #expect(scroll.hiddenAbove == 27)
    }

    @Test func scrolledBackTheLinesBeingReadStayInPlace() {
        var scroll = TranscriptScroll()
        scroll.setOverflow(47)
        scroll.scroll(by: 100)
        // Stops at the first line.
        #expect(scroll.offset == 47 && scroll.hiddenAbove == 0)
        // A new line below: the first line stays at the top.
        scroll.setOverflow(67)
        #expect(scroll.hiddenAbove == 0 && scroll.hiddenBelow == 67)
        scroll.scroll(by: -30)
        scroll.setOverflow(87)
        #expect(scroll.hiddenAbove == 30)
        // Scrolled to the end, it follows again.
        scroll.scroll(by: -200)
        scroll.setOverflow(107)
        #expect(scroll.offset == 0)
    }

    @Test func shorterTextStaysInTheBox() {
        var scroll = TranscriptScroll()
        scroll.setOverflow(67)
        scroll.scroll(by: 40)
        // The recognizer took back a line.
        scroll.setOverflow(27)
        #expect(scroll.offset == 0)
        scroll.setOverflow(0)
        scroll.scroll(by: 10)
        #expect(scroll.offset == 0)
    }
}

struct ShownSpeechTests {
    @Test func exactWordsReplaceWhatWasSaidBeforeThePause() {
        var speech = ShownSpeech()
        speech.hear("Butget hop上那个评论总结一下", from: 0, isFinal: false)
        // Live finalized its own phrase in the quiet.
        speech.hear("Butget hop上那个评论总结一下。", from: 0, isFinal: true)
        speech.hear("。", from: 4.5, isFinal: false)
        speech.hearExactly("把 GitHub上那个评论总结一下。", through: 5.1)
        #expect(speech.text == "把 GitHub 上那个评论总结一下。")
        // Live results from before the pause, late: already in the exact words.
        speech.hear("Butget hop上那个评论总结一下。", from: 4.5, isFinal: true)
        #expect(speech.text == "把 GitHub 上那个评论总结一下。")
    }

    @Test func wordsAfterThePauseStayLive() {
        var speech = ShownSpeech()
        speech.hear("帮我订会议室", from: 0, isFinal: false)
        // The person went on before the exact words came.
        speech.hear("把 Ficma", from: 3.12, isFinal: false)
        speech.hearExactly("帮我订会议室。", through: 3.1)
        #expect(speech.text == "帮我订会议室。把 Ficma")
        // A later result of the same pause revises its exact words.
        speech.hearExactly("帮我定会议室。", through: 3.1)
        #expect(speech.text == "帮我定会议室。把 Ficma")
    }

    @Test func aDraftStaysAsTyped() {
        var speech = ShownSpeech(draft: "Book the  room")
        speech.hear("for Friday", from: 0, isFinal: false)
        #expect(speech.text == "Book the  room for Friday")
        #expect(speech.spoken == "for Friday")
    }
}
