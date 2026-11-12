import CoreGraphics
import CUShared
import Foundation

/// Watches a paused state machine for the user "calming down" — mouse
/// stops near the paused position OR keyboard goes idle — and flips the
/// session back to `.active`.
///
/// Slim port of legacy `RecoveryMonitor.swift`. Same heuristics
/// (proximity + still-mouse + minimum dwell), simpler plumbing.
@MainActor
public final class RecoveryMonitor {
    public weak var stateMachine: StateMachine?
    public var onRecovery: (() -> Void)?

    private var lastDiagnosticAt = Date.distantPast
    private var monitorTimer: Timer?
    private var lastMousePosition: CGPoint = .zero
    private var mouseStillSince: Date?
    private var lastKeyTime: Date?
    private var interventionStartedAt: Date?
    private var countdownTimer: Timer?

    private let mouseProximityThreshold: CGFloat = 50
    private let mouseHoldDuration: TimeInterval = 1.0
    private let mouseStillThreshold: CGFloat = 3.0
    private let keyboardIdleDuration: TimeInterval = 3.0
    private let minimumInterventionDuration: TimeInterval = 3.0

    public init() {}

    public func startMonitoring() {
        stopMonitoring()
        lastMousePosition = CGEvent(source: nil)?.location ?? .zero
        mouseStillSince = nil
        interventionStartedAt = Date()
        lastDiagnosticAt = .distantPast
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    public func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        lastKeyTime = nil
        mouseStillSince = nil
        interventionStartedAt = nil
    }

    public func recordKeyEvent() {
        lastKeyTime = Date()
    }

    private func tick() {
        guard let sm = stateMachine, sm.isPaused else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        switch sm.interventionType {
        case .mouse: checkMouseRecovery(sm)
        case .keyboard: checkKeyboardRecovery()
        case .none: break
        }
    }

    private func checkMouseRecovery(_ sm: StateMachine) {
        guard let paused = sm.pausedIntervention else {
            cancelCountdown()
            mouseStillSince = nil
            return
        }
        let now = CGEvent(source: nil)?.location ?? .zero
        let moveDelta = hypot(now.x - lastMousePosition.x, now.y - lastMousePosition.y)
        lastMousePosition = now
        if moveDelta > mouseStillThreshold {
            if Date().timeIntervalSince(lastDiagnosticAt) >= 2 {
                lastDiagnosticAt = Date()
                ForegroundModeRuntime.diagnostics.info("recovery_blocked reason=mouse_moving movement=\(moveDelta)")
            }
            mouseStillSince = nil
            cancelCountdown()
            return
        }
        if mouseStillSince == nil { mouseStillSince = Date() }

        let dx = now.x - paused.screenPoint.x
        let dy = now.y - paused.screenPoint.y
        let distance = sqrt(dx * dx + dy * dy)

        if Date().timeIntervalSince(lastDiagnosticAt) >= 2 {
            lastDiagnosticAt = Date()
            ForegroundModeRuntime.diagnostics.info("recovery_check kind=mouse distance=\(distance) threshold=\(self.mouseProximityThreshold) movement=\(moveDelta) countdown=\(self.countdownTimer != nil)")
        }
        if distance <= mouseProximityThreshold {
            if countdownTimer == nil {
                let elapsed = interventionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                let remainingMinimum = max(0, minimumInterventionDuration - elapsed)
                let delay = max(mouseHoldDuration, remainingMinimum)
                countdownTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.triggerRecovery() }
                }
            }
        } else {
            cancelCountdown()
        }
    }

    private func checkKeyboardRecovery() {
        guard let last = lastKeyTime else {
            lastKeyTime = Date()
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        if Date().timeIntervalSince(lastDiagnosticAt) >= 2 {
            lastDiagnosticAt = Date()
            ForegroundModeRuntime.diagnostics.info("recovery_check kind=keyboard idle_seconds=\(elapsed)")
        }
        if elapsed >= keyboardIdleDuration {
            triggerRecovery()
        }
    }

    private func triggerRecovery() {
        guard let sm = stateMachine, sm.isPaused, let paused = sm.pausedIntervention else { return }
        if let started = interventionStartedAt,
           Date().timeIntervalSince(started) < minimumInterventionDuration
        {
            return
        }
        ForegroundModeRuntime.diagnostics.notice("recovery_trigger warp_x=\(paused.screenPoint.x) warp_y=\(paused.screenPoint.y)")
        CGWarpMouseCursorPosition(paused.screenPoint)
        cancelCountdown()
        mouseStillSince = nil
        onRecovery?()
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
}
