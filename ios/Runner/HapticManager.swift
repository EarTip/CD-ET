import UIKit
import AVFoundation
import CoreHaptics

class HapticManager {
    private var engine: CHHapticEngine?
    private var currentPlayer: CHHapticPatternPlayer?
    private var needsStart = true
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    init() {
        if supportsHaptics {
            try? AVAudioSession.sharedInstance()
                .setAllowHapticsAndSystemSoundsDuringRecording(true)
            createEngine()
        }
    }

    private func createEngine() {
        do {
            let newEngine = try CHHapticEngine()
            newEngine.playsHapticsOnly = true

            newEngine.stoppedHandler = { [weak self] _ in
                self?.needsStart = true
                try? self?.engine?.start()
                self?.needsStart = false
            }

            newEngine.resetHandler = { [weak self] in
                self?.engine = nil
                self?.needsStart = true
            }

            try newEngine.start()
            engine = newEngine
            needsStart = false
        } catch {
            engine = nil
        }
    }

    private func ensureEngine() throws {
        if engine == nil { createEngine() }
        guard let engine else { throw CHHapticError(.engineNotRunning) }
        if needsStart {
            try engine.start()
            needsStart = false
        }
    }

    // MARK: - 테스트: fallback만 사용 (CoreHaptics 문제 격리용)
    func playSirenHaptic()     { fallbackSiren() }
    func playHornHaptic()      { fallbackHorn() }
    func playBrakeHaptic()     { fallbackBrake() }
    func playNameCalledHaptic(){ fallbackNameCalled() }

    // MARK: - CoreHaptics 재생
    private func playAdvanced(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) -> Bool {
        guard supportsHaptics else { return false }
        do {
            try ensureEngine()
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            currentPlayer = try engine?.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            engine = nil
            needsStart = true
            do {
                try ensureEngine()
                let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
                currentPlayer = try engine?.makePlayer(with: pattern)
                try currentPlayer?.start(atTime: CHHapticTimeImmediate)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - UIFeedbackGenerator Fallback
    private func fallbackSiren() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            gen.notificationOccurred(.warning)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            gen.notificationOccurred(.warning)
        }
    }

    private func fallbackHorn() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        gen.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            gen.impactOccurred()
        }
    }

    private func fallbackBrake() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
    }

    private func fallbackNameCalled() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) {
                gen.impactOccurred()
            }
        }
    }
}