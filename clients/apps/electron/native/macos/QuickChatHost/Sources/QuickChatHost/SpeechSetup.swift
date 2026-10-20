import AppKit
import Foundation
import QuickChatCore
import Speech

/// Which transcribers hear Quick Chat's microphone, how Enter finishes them
/// and which text it sends. It holds no audio engine or windows, so an
/// offline benchmark can compile this file and measure exactly what ships.
///
/// Two analyzers hear the same audio:
///
/// - `live` shows the words while they are spoken, in the person's language.
///   Fast results update it about once a second; without them nothing shows
///   until a phrase ends.
/// - `exact` transcribes in the person's language and in their second
///   language, without fast results, which drop and misspell words.
///
/// Each pause (`SpeechPause`) and Enter finalize the audio both have (about
/// 0.1 s). The exact words then replace the live ones, each sentence in the
/// language it was spoken in (`ExactSpeech`): a Mandarin speaker's English
/// sentence arrives as English, and the last words said before Enter are
/// kept. Misheard product names are corrected before they show (`sent`).
struct SpeechSetup {
    let live: SpeechTranscriber
    /// The person's language first.
    let exact: [SpeechTranscriber]
    /// The exact transcribers' languages.
    let languages: [Locale]

    /// The longest Enter waits for the final words before it sends what is shown.
    static let finishLimit: Duration = .seconds(1)

    init(language: Locale, second: Locale? = nil) {
        live = SpeechTranscriber(
            locale: language,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        languages = [language, second].compactMap { $0 }
        exact = languages.map { locale in
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
        }
    }

    var modules: [any SpeechModule] { [live] + exact }

    /// The live analyzer, then the exact one. Each reads its own stream of
    /// the same buffers.
    func analyzers() -> [SpeechAnalyzer] {
        [SpeechAnalyzer(modules: [live]), SpeechAnalyzer(modules: exact)]
    }

    /// The language the person speaks to their Mac, then the next of their
    /// preferred languages that the transcriber knows and that is another
    /// language, such as zh-CN then en-US. The first is Siri's language, else
    /// the first preferred language the transcriber knows; the UI language can
    /// differ (an English Mac whose owner talks to Siri in Chinese).
    static func languages() async -> [Locale] {
        let siri = UserDefaults(suiteName: "com.apple.assistant.backedup")?.string(forKey: "Session Language")
        var result: [Locale] = []
        for identifier in [siri].compactMap({ $0 }) + Locale.preferredLanguages {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)),
                  !result.contains(where: { $0.language.languageCode == locale.language.languageCode })
            else { continue }
            result.append(locale)
            if result.count == 2 { break }
        }
        return result
    }

    /// Waits until every analyzer has finalized the input it has, at most
    /// `finishLimit`. The input streams must have ended. False when an
    /// analyzer failed or the limit passed; the analyzers are then cancelled
    /// and their results may stop short.
    static func finalize(_ analyzers: [SpeechAnalyzer]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for analyzer in analyzers {
                group.addTask {
                    do {
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: finishLimit)
                return false
            }
            var finalized = 0
            while finalized < analyzers.count, let done = await group.next() {
                guard done else {
                    for analyzer in analyzers { await analyzer.cancelAndFinishNow() }
                    group.cancelAll()
                    return false
                }
                finalized += 1
            }
            group.cancelAll()
            return true
        }
    }

    /// What Enter sends of `text`: the same words with misheard product names
    /// corrected (`ProductNames`). The spell checker's English dictionary says
    /// which words are real; it is only read, in a document of its own.
    @MainActor
    static func sent(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        let document = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: document) }
        return ProductNames.corrected(text) { word in
            checker.checkSpelling(
                of: word, startingAt: 0, language: "en", wrap: false,
                inSpellDocumentWithTag: document, wordCount: nil
            ).location == NSNotFound
        }
    }
}

extension ExactSpeech.Segment {
    /// Time-coded runs keep a forced clip boundary from replacing a whole
    /// sentence that also contains words on the other side of that boundary.
    static func segments(_ result: SpeechTranscriber.Result) -> [Self] {
        segments(result.text, range: result.range)
    }

    static func segments(_ text: AttributedString, range: CMTimeRange) -> [Self] {
        var timed: [(start: Double, end: Double, text: String, confidence: [Double])] = []
        var leading = ""
        for run in text.runs {
            let words = String(text[run.range].characters)
            guard let time = run.audioTimeRange else {
                if timed.isEmpty { leading += words } else { timed[timed.count - 1].text += words }
                continue
            }
            let wordsWithPrefix = leading + words
            leading = ""
            let confidence = run.transcriptionConfidence.map { [Double($0)] } ?? []
            // Adjacent ASCII runs without a space can be one word, decimal,
            // domain, or contraction. Keep that token and its punctuation whole.
            if let last = timed.last?.text.last, let first = wordsWithPrefix.first,
               last.isASCII, first.isASCII, !last.isWhitespace, !first.isWhitespace {
                timed[timed.count - 1].text += wordsWithPrefix
                timed[timed.count - 1].end = time.end.seconds
                timed[timed.count - 1].confidence += confidence
            } else {
                timed.append((time.start.seconds, time.end.seconds, wordsWithPrefix, confidence))
            }
        }
        guard !timed.isEmpty else {
            return [Self(
                start: range.start.seconds, end: range.end.seconds,
                text: String(text.characters),
                confidences: text.runs.compactMap(\.transcriptionConfidence)
            )]
        }
        return timed.enumerated().map { index, run in
            Self(start: run.start, end: run.end, text: run.text, confidences: run.confidence,
                 continuesPrevious: index > 0)
        }
    }
}

extension Locale {
    /// Written in Han, kana or Hangul.
    var writesCJK: Bool {
        ["zh", "ja", "ko", "yue"].contains(language.languageCode?.identifier ?? "")
    }
}
