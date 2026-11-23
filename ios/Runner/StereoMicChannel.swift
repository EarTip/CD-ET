import Flutter
import AVFoundation

/// iOS 방향 추정용 마이크 입력. iPhone 내장 마이크는 기본이 모노라서, 스테레오 극성 패턴(iOS 14+)을
/// 켜고 AVAudioEngine으로 직접 녹음해야 L/R이 서로 다른 신호가 된다.
/// `record` 플러그인 경로는 스테레오 패턴이 켜져 있어도 L/R을 같은 신호로 뭉개므로 쓰지 않는다.
/// 실기기에서 윗변/아랫변 소리의 L/R 지연 부호가 반대로 나오는 것을 확인했다
/// (스테레오 패턴은 OS가 만든 L/R이라 유효 간격이 실제 마이크 간격보다 크다 — TdoaAnalyzer 참고).
/// 사용 순서: `enable`(극성 패턴 설정) → `startCapture`(16kHz 스테레오 PCM16을 `stereo_mic_events`로 전송) → `stopCapture`.
class StereoMicChannel {
    private var channel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private let streamHandler = CaptureStreamHandler()
    private var captureEngine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    /// 목표 샘플레이트. Dart(YAMNet·TDOA)가 16kHz 기준이다.
    private static let outputSampleRate = 16000.0

    private final class CaptureStreamHandler: NSObject, FlutterStreamHandler {
        var sink: FlutterEventSink?
        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            sink = events
            return nil
        }
        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            sink = nil
            return nil
        }
    }

    func register(with messenger: FlutterBinaryMessenger) {
        eventChannel = FlutterEventChannel(name: "stereo_mic_events", binaryMessenger: messenger)
        eventChannel?.setStreamHandler(streamHandler)
        channel = FlutterMethodChannel(name: "stereo_mic_channel", binaryMessenger: messenger)
        channel?.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "startCapture":
                self?.startCapture(result: result)
            case "stopCapture":
                self?.stopCapture()
                result(nil)
            case "enable":
                let args = call.arguments as? [String: Any]
                self?.enableStereoPrimed(orientation: args?["orientation"] as? String, result: result)
            case "status":
                result(self?.currentStatus())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// 스테레오 극성 패턴은 세션에서 입출력이 한 번 돈 뒤에야 적용되는 것으로 보인다
    /// (엔진을 돌린 직후에 같은 설정을 하면 Stereo로 읽히고, 설정만 하고 바로 읽으면 Omnidirectional).
    /// 그래서 설정 → 엔진을 잠깐 돌림 → 다시 설정 순서로 한다.
    private func enableStereoPrimed(orientation: String?, result: @escaping FlutterResult) {
        let first = enableStereo(orientation: orientation)
        if first["stereo"] as? Bool == true {
            result(first)
            return
        }

        // 세션이 비활성(0ch)이면 입력 포맷이 유효하지 않아 탭을 걸 수 없으므로 먼저 활성화한다.
        try? AVAudioSession.sharedInstance().setActive(true)
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            var info = first
            info["primeError"] = "입력 포맷이 유효하지 않음 (\(format.channelCount)ch)"
            result(info)
            return
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        do {
            try engine.start()
        } catch {
            var info = first
            info["primeError"] = error.localizedDescription
            result(info)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            var info = self?.enableStereo(orientation: orientation) ?? first
            info["primed"] = true
            result(info)
        }
    }

    // MARK: - 네이티브 캡처

    /// `record` 플러그인을 거치지 않고 AVAudioEngine으로 직접 녹음한다. record 경로는 스테레오 패턴이
    /// 켜져 있어도 L/R이 같은 신호로 뭉개지지만, 엔진으로 직접 받으면 두 마이크가 서로 다른 신호다.
    /// 입력(보통 48kHz 2ch float)을 16kHz 2ch Int16 인터리브로 바꿔 EventChannel로 보낸다 — record가
    /// 주던 PCM과 같은 형식이라 Dart의 기존 처리를 그대로 쓴다.
    /// 호출 전에 `enable`로 스테레오 극성 패턴을 먼저 맞춰 두어야 한다.
    private func startCapture(result: @escaping FlutterResult) {
        stopCapture()
        do {
            try startEngine()
        } catch {
            result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
            return
        }
        var info = currentStatus()
        info["engineChannels"] = captureEngine?.inputNode.outputFormat(forBus: 0).channelCount ?? 0
        result(info)

        // 오디오 장치가 바뀌거나 다른 앱이 세션을 가져갔다 돌려주면 엔진이 멈춘다. 다시 올린다.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            // 엔진을 다시 만들면 객체가 바뀌므로 특정 엔진에 묶지 않고, 지금 캡처 중인 엔진의 알림만 처리한다.
            guard let self = self, let current = self.captureEngine,
                  (note.object as? AVAudioEngine) === current else { return }
            do {
                try self.startEngine()
            } catch {
                self.streamHandler.sink?(FlutterError(code: "CAPTURE_RESTART_FAILED",
                                                      message: error.localizedDescription, details: nil))
            }
        }
    }

    private func startEngine() throws {
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()

        try AVAudioSession.sharedInstance().setActive(true)
        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount == 2 else {
            throw NSError(domain: "StereoMicChannel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "입력이 2채널이 아님 (\(inputFormat.channelCount)ch)",
            ])
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: Self.outputSampleRate,
                                            channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw NSError(domain: "StereoMicChannel", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "샘플레이트 변환기를 만들지 못함",
            ])
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // 컨버터는 탭 콜백(직렬)에서만 쓰므로 필터 상태가 버퍼 사이에 이어진다.
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.outputSampleRate
                                             / buffer.format.sampleRate) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            let data = Data(bytes: samples[0], count: Int(out.frameLength) * 2 * MemoryLayout<Int16>.size)
            DispatchQueue.main.async { self?.streamHandler.sink?(FlutterStandardTypedData(bytes: data)) }
        }
        try engine.start()
        captureEngine = engine
    }

    private func stopCapture() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
    }

    /// 지금 세션이 실제로 잡고 있는 입력 상태 (다른 코드가 세션을 다시 설정했는지 확인용)
    private func currentStatus() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let source = session.preferredInput?.selectedDataSource
        return [
            "channels": session.inputNumberOfChannels,
            "dataSource": source?.dataSourceName ?? "-",
            "polarPattern": source?.selectedPolarPattern?.rawValue ?? "-",
        ]
    }

    /// 결과는 Dart 디버그 표시용. `stereo`가 false면 이 기기·경로에서는 스테레오를 얻지 못한 것이다.
    private func enableStereo(orientation: String?) -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        var info: [String: Any] = ["stereo": false]

        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            info["reason"] = "내장 마이크 입력 없음"
            return info
        }

        // Apple 샘플(Capturing stereo audio from built-in microphones)과 같은 순서:
        // preferredInput 지정 → 그 입력의 데이터 소스에 stereo 패턴 → 데이터 소스 지정 → 방향 지정.
        // 채널 수(setPreferredInputNumberOfChannels)는 샘플에 없으므로 여기서 건드리지 않는다.
        do {
            try session.setPreferredInput(builtIn)
        } catch {
            info["reason"] = "setPreferredInput: \(error.localizedDescription)"
            return info
        }

        guard let input = session.preferredInput,
              let source = input.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.stereo) == true }) else {
            info["reason"] = "스테레오 극성 패턴을 지원하는 마이크 없음"
            return info
        }

        var failed: String?
        func attempt(_ step: String, _ body: () throws -> Void) {
            guard failed == nil else { return }
            do { try body() } catch { failed = "\(step): \(error.localizedDescription)" }
        }
        attempt("setPreferredPolarPattern") { try source.setPreferredPolarPattern(.stereo) }
        attempt("setPreferredDataSource") { try input.setPreferredDataSource(source) }
        attempt("setPreferredInputOrientation") {
            try session.setPreferredInputOrientation(Self.interfaceOrientation(orientation))
        }

        // 읽을 때도 샘플처럼 세션의 현재 선택 상태를 기준으로 한다.
        let selected = session.preferredInput?.selectedDataSource
        let pattern = selected?.selectedPolarPattern
        info["stereo"] = failed == nil && pattern == .stereo
        if info["stereo"] as? Bool != true {
            info["reason"] = failed ?? "극성 패턴이 stereo가 아님 (\(pattern?.rawValue ?? "-"), \(session.inputNumberOfChannels)ch)"
        }
        info["channels"] = session.inputNumberOfChannels
        info["maxChannels"] = session.maximumInputNumberOfChannels
        info["dataSource"] = selected?.dataSourceName ?? source.dataSourceName
        info["polarPattern"] = pattern?.rawValue ?? "-"
        info["orientation"] = orientation ?? "landscapeLeft"
        return info
    }

    /// 스테레오 L/R은 지정한 방향 기준 좌우로 잡힌다. 폰을 세로로 든 채 상단/하단 마이크를
    /// L/R로 쓰려면 가로 방향을 지정해야 한다. 어느 쪽이 상단인지는 기기에서 확인한다.
    private static func interfaceOrientation(_ name: String?) -> AVAudioSession.StereoOrientation {
        switch name {
        case "portrait": return .portrait
        case "portraitUpsideDown": return .portraitUpsideDown
        case "landscapeRight": return .landscapeRight
        default: return .landscapeLeft
        }
    }
}
