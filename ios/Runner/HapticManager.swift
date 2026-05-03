import CoreHaptics

class HapticManager {
    private var engine: CHHapticEngine?

    init() {
        prepareEngine()
    }

    private func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.playsHapticsOnly = true  // 오디오 세션 미점유 → TTS 동시 사용 가능
            try engine?.start()

            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
        } catch {
            print("햅틱 엔진 초기화 실패: \(error)")
        }
    }

    // MARK: - 🚨 사이렌: 파동형 반복 패턴
    func playSirenHaptic() {
        var events: [CHHapticEvent] = []
        
        // 강도가 올라갔다 내려오는 파동 3사이클
        for cycle in 0..<3 {
            let baseTime = Double(cycle) * 0.6
            
            // 올라가는 구간
            let riseParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3 + Float(cycle) * 0.1)
            let sharpParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
            let rise = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [riseParam, sharpParam],
                relativeTime: baseTime,
                duration: 0.3
            )
            
            // 내려가는 구간
            let fallParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.1)
            let fall = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [fallParam, sharpParam],
                relativeTime: baseTime + 0.3,
                duration: 0.2
            )
            
            events.append(contentsOf: [rise, fall])
        }
        play(events)
    }

    // MARK: - 📯 경적: 짧고 강한 단타 2회
    func playHornHaptic() {
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        
        let first = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0.0
        )
        let second = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [intensity, sharpness],
            relativeTime: 0.25  // 250ms 후 2번째
        )
        play([first, second])
    }

    // MARK: - 🛑 급브레이크: 강한 충격 + 여운 진동
    func playBrakeHaptic() {
        // 강한 초기 충격
        let impactIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        let impactSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
        let impact = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [impactIntensity, impactSharpness],
            relativeTime: 0.0
        )
        
        // 마찰음 같은 여운 (강도가 점점 줄어드는 연속 진동)
        let rumbleIntensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
        let rumbleSharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [rumbleIntensity, rumbleSharpness],
            relativeTime: 0.05,
            duration: 0.4
        )
        
        // 강도 감소 커브 적용
        let decayCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.0, value: 1.0),
                .init(relativeTime: 0.4, value: 0.0)  // 점점 약해짐
            ],
            relativeTime: 0.05
        )
        
        play([impact, rumble], curves: [decayCurve])
    }

    // MARK: - 📢 이름 부르기: 부드러운 탭 3회
    func playNameCalledHaptic() {
        var events: [CHHapticEvent] = []
        
        for i in 0..<3 {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2) // 낮을수록 부드러움
            let tap = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensity, sharpness],
                relativeTime: Double(i) * 0.35  // 350ms 간격으로 여유있게
            )
            events.append(tap)
        }
        play(events)
    }

    // MARK: - 공통 실행 메서드
    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) {
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("햅틱 재생 실패: \(error)")
        }
    }
}
