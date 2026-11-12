import AppKit
import CoreGraphics
import CUShared
import Foundation

/// Orchestrates the observe-the-user-while-paused flow.
///
/// Lifecycle:
///   1. `start(sessionStartedAt:)` is called when the foreground session
///      activates.
///   2. Each time the InterventionDetector fires, the runtime calls
///      `beginRound()`. The manager takes a screenshot every
///      `captureIntervalMs`, sends it to the backend with the rolling
///      timeline, and records the returned single-sentence summary.
///   3. When the RecoveryMonitor fires, the runtime calls
///      `endRoundAndRequestFinal()`. The manager asks the backend for a
///      detailed final summary (gated by `finalSummaryTimeoutMs`) and
///      delivers it via the `onSummary` callback so the HUD can show it
///      and the agent can pick up context.
///   4. `stop()` tears everything down on session deactivation.
///
/// Slim port of legacy `Observer/ObserverManager.swift` + coordinator +
/// worker + capture service + timeline. The legacy stack also tracked
/// per-event cursor trails and rendered them into crops; the slim
/// version relies on whole-display ScreenCapture (including the
/// colorful border + HUD for context) and skips cursor-trail rendering.
@MainActor
public final class ObserverManager {
    public var onSummary: ((String) -> Void)?
    public var onError: ((ObserverRuntimeError) -> Void)?

    public var isConfigured: Bool {
        configuration.summaryBackend != nil
    }

    private var configuration: ObservationConfiguration
    private var session: (any AgentSummarySession)?
    private var sessionStartedAtMs: Double = 0

    private var timelineEntries: [ObserverTimelineEntry] = []
    private var roundIndex: Int = 0
    private var sequence: Int = 0

    private var captureTask: Task<Void, Never>?
    private var isCapturing = false

    public init(configuration: ObservationConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Replace the backend config before `start()`. Safe to call while
    /// the observer is stopped.
    public func updateConfiguration(_ configuration: ObservationConfiguration) {
        self.configuration = configuration
    }

    public func start(sessionStartedAt: Double = observerNowMs()) {
        guard let backend = configuration.summaryBackend else { return }
        sessionStartedAtMs = sessionStartedAt
        session = backend.makeSession { message in
            // Route backend logs to stderr so developers can watch the
            // daemon log without them leaking into action responses.
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        timelineEntries.removeAll(keepingCapacity: true)
        roundIndex = 0
        sequence = 0
    }

    public func stop() {
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
        session = nil
        timelineEntries.removeAll(keepingCapacity: true)
    }

    /// Begin a new observation round — start the screenshot-every-N-seconds
    /// capture loop. Called from `ForegroundModeRuntime.handleInterventionPaused`.
    public func beginRound() {
        guard isConfigured, session != nil, !isCapturing else { return }
        roundIndex += 1
        isCapturing = true
        let interval = configuration.captureIntervalMs
        captureTask = Task { [weak self] in
            await self?.captureLoop(intervalMs: interval)
        }
    }

    /// End the current round and ask the backend for the detailed final
    /// summary. Returns the summary text on success, `nil` if not
    /// configured or on timeout/failure (the `onError` callback fires in
    /// the error cases).
    @discardableResult
    public func endRoundAndRequestFinal() async -> String? {
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false

        guard let session else { return nil }

        // Capture one last frame so the final summary has the
        // post-intervention screen state.
        await captureOnce()

        let timeoutMs = configuration.finalSummaryTimeoutMs
        let snapshot = timelineEntries
        let started = sessionStartedAtMs

        let result: ObserverFinalSummaryResult = await withTaskGroup(of: ObserverFinalSummaryResult.self) { group in
            group.addTask {
                do {
                    let text = try await session.requestFinalSummary(
                        timelineEntries: snapshot,
                        sessionStartedAt: started
                    )
                    return .success(text)
                } catch let error as ObserverRuntimeError {
                    return .failure(error.description)
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                return .timeout(timeoutMs)
            }
            if let first = await group.next() {
                group.cancelAll()
                return first
            }
            return .failure("no result")
        }

        switch result {
        case let .success(text):
            onSummary?(text)
            return text
        case let .timeout(ms):
            onError?(.summaryTimedOut(ms))
            return nil
        case let .failure(msg):
            onError?(.summaryRequestFailed(msg, fatal: false))
            return nil
        case .notConfigured:
            return nil
        }
    }

    // MARK: - Capture loop

    private func captureLoop(intervalMs: Int) async {
        let intervalNs = UInt64(intervalMs) * 1_000_000
        while !Task.isCancelled {
            await captureOnce()
            // Dispatch round-summary in parallel with next capture so the
            // cadence stays tight.
            let snapshot = timelineEntries
            let started = sessionStartedAtMs
            let roundIdx = roundIndex
            if let session {
                Task { [weak self] in
                    await self?.requestRoundSummary(
                        using: session,
                        timeline: snapshot,
                        roundIndex: roundIdx,
                        sessionStartedAt: started
                    )
                }
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }

    private func captureOnce() async {
        do {
            let out = try await ScreenCapture.captureToPNG()
            guard let data = try? Data(contentsOf: out.url) else { return }
            let base64 = data.base64EncodedString()
            sequence += 1
            timelineEntries.append(
                ObserverTimelineEntry(
                    type: .capture,
                    timestampMs: observerNowMs(),
                    frameBase64: base64,
                    frameMimeType: "image/png",
                    displayIndex: 1,
                    sequence: sequence
                )
            )
        } catch {
            onError?(.summaryRequestFailed("capture failed: \(error)", fatal: false))
        }
    }

    private func requestRoundSummary(
        using session: any AgentSummarySession,
        timeline: [ObserverTimelineEntry],
        roundIndex: Int,
        sessionStartedAt: Double
    ) async {
        do {
            let text = try await session.summarizeObservation(
                timelineEntries: timeline,
                roundIndex: roundIndex,
                sessionStartedAt: sessionStartedAt
            )
            guard text != "[NO_ACTION]。", text != "[NO_ACTION]" else { return }
            await MainActor.run {
                self.sequence += 1
                self.timelineEntries.append(
                    ObserverTimelineEntry(
                        type: .summary,
                        timestampMs: observerNowMs(),
                        text: text,
                        sequence: self.sequence
                    )
                )
                self.onSummary?(text)
            }
        } catch let error as ObserverRuntimeError {
            await MainActor.run { self.onError?(error) }
        } catch {
            await MainActor.run {
                self.onError?(.summaryRequestFailed(error.localizedDescription, fatal: false))
            }
        }
    }
}

public extension ObservationConfiguration {
    /// Build a configuration from caller-supplied `ObserverStartArgs`.
    /// If no bridge socket is supplied, the observer remains a silent no-op.
    static func fromStartArgs(_ args: ObserverStartArgs?) -> ObservationConfiguration {
        let backend: (any AgentSummaryBackend)? = {
            if let path = args?.bridgeSocketPath?.nonEmpty {
                return BridgeObserverSummaryBackend(socketPath: path)
            }
            return nil
        }()

        return ObservationConfiguration(
            summaryBackend: backend,
            captureIntervalMs: args?.captureIntervalMs ?? 3000,
            finalSummaryTimeoutMs: args?.finalSummaryTimeoutMs ?? 10000
        )
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
