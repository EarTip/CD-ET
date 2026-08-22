// VoiceActivityDetector는 플러그인/플랫폼 의존성이 없다(dart:async, dart:math,
// flutter/foundation.dart의 debugPrint/Float32List, 그리고 순수 값 타입인
// RawAudioChunk뿐) — mel_frontend_test.dart와 마찬가지로 기기 없이 `flutter
// test`로 검증 가능하다. 합성 오디오 프레임을 Stream<RawAudioChunk>로 흘려
// 넣고 utteranceStream에 뭐가 나오는지만 관찰하면 되므로, 프로덕션 코드는
// 전혀 손대지 않고 테스트할 수 있다.

import 'dart:async';
import 'dart:typed_data';

import 'package:eartips/services/tdoa_analyzer.dart' show RawAudioChunk;
import 'package:eartips/services/voice_activity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleRate = 16000;
const _frameMs = 20;
const _frameSize = _sampleRate * _frameMs ~/ 1000; // 320 samples/frame

/// 진폭이 일정한 프레임 하나. 0.0 = 무음, 0.2(≈ -14dB) = VAD가 확실히
/// 발화로 인식할 만큼 큰 진폭(노이즈 플로어가 클램프 하한 -70dB까지 내려가도
/// onset 마진 12dB를 여유 있게 넘음).
RawAudioChunk _frame(double value) {
  final samples = Float32List(_frameSize)..fillRange(0, _frameSize, value);
  return RawAudioChunk(samples, samples, false);
}

/// StreamController.add()는 마이크로태스크로 전달되므로, VAD의 동기 처리와
/// utteranceStream 리스너까지 실행되도록 한 틱 흘려보낸 뒤 리턴한다.
Future<void> _feed(StreamController<RawAudioChunk> src, double value,
    [int count = 1]) async {
  for (var i = 0; i < count; i++) {
    src.add(_frame(value));
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('오프셋(무음) 기반 발화 종료 — 기존 동작 회귀 확인', () {
    test('발화 후 hangover만큼 무음이 이어지면 정확히 하나의 발화를 방출한다',
        () async {
      final vad = VoiceActivityDetector();
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      vad.start(src.stream);
      vad.utteranceStream.listen(emitted.add);

      await _feed(src, 0.0, 10); // preRoll(7프레임)보다 넉넉한 무음 리드인
      await _feed(src, 0.2, 20); // 발화 400ms — minSpeechMs(300ms)보다 김
      expect(emitted, isEmpty, reason: 'hangover 전이라 아직 방출되면 안 됨');

      await _feed(src, 0.0, 16); // hangover(300ms=15프레임) 이상 무음

      expect(emitted.length, 1);
      // preRoll(140ms=2240샘플) + 발화(400ms=6400샘플) = 8640샘플
      expect(emitted.single.left.length, 2240 + 6400);

      await vad.stop();
      vad.dispose();
      await src.close();
    });

    test('minSpeechMs보다 짧은 blip은 폐기된다', () async {
      final vad = VoiceActivityDetector();
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      vad.start(src.stream);
      vad.utteranceStream.listen(emitted.add);

      await _feed(src, 0.0, 10);
      await _feed(src, 0.2, 5); // 발화 100ms — minSpeechMs(300ms)보다 짧음
      await _feed(src, 0.0, 16);

      expect(emitted, isEmpty, reason: '너무 짧은 발화는 blip으로 버려져야 함');

      await vad.stop();
      vad.dispose();
      await src.close();
    });
  });

  group('조기 방출(earlyEmitSamples)', () {
    const earlyEmitSamples = 8000; // 테스트용 임의 목표 길이(500ms 상당)

    test('목표 길이보다 짧게 끝나면 기존처럼 오프셋으로 판정한다', () async {
      final vad = VoiceActivityDetector();
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      vad.start(src.stream, earlyEmitSamples: earlyEmitSamples);
      vad.utteranceStream.listen(emitted.add);

      await _feed(src, 0.0, 10);
      await _feed(src, 0.2, 10); // 200ms — earlyEmitSamples(500ms)보다 짧음
      await _feed(src, 0.0, 16);

      expect(emitted.length, 1);
      expect(emitted.single.left.length, lessThan(earlyEmitSamples));

      await vad.stop();
      vad.dispose();
      await src.close();
    });

    test('목표 길이에 도달하면 무음 없이도 바로 방출한다', () async {
      final vad = VoiceActivityDetector();
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      vad.start(src.stream, earlyEmitSamples: earlyEmitSamples);
      vad.utteranceStream.listen(emitted.add);

      await _feed(src, 0.0, 10);
      // 무음 구간 없이 발화만 계속 흘려보낸다 — offset(hangover)이 트리거될
      // 기회를 아예 주지 않는다.
      await _feed(src, 0.2, 25);

      expect(emitted, isNotEmpty,
          reason: '무음 없이도 목표 길이 도달만으로 방출돼야 함');
      // 목표 길이(+프레임 한 개 오차) 근처에서 끊겼는지 — 25프레임(8000샘플)
      // 전체를 다 채울 때까지 기다린 게 아니라는 것을 확인.
      expect(emitted.first.left.length, greaterThanOrEqualTo(earlyEmitSamples));
      expect(emitted.first.left.length, lessThan(earlyEmitSamples + _frameSize));

      await vad.stop();
      vad.dispose();
      await src.close();
    });

    test(
        '발화가 목표 길이의 배수만큼 계속되면 쿨다운 간격을 두고 반복 '
        '방출되고, 두 번째부터는 preRoll이 비어 있다(설계상 알아둬야 할 특성)',
        () async {
      const cooldownMs = 200; // 기본값과 동일 — 향후 기본값이 바뀌어도
      // 이 테스트의 프레임 수 계산이 안 흔들리도록 명시적으로 넘긴다.
      final vad = VoiceActivityDetector(cooldownMs: cooldownMs);
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      vad.start(src.stream, earlyEmitSamples: earlyEmitSamples);
      vad.utteranceStream.listen(emitted.add);

      await _feed(src, 0.0, 10);
      // 1번째 방출까지 18프레임 + 쿨다운 10프레임(스킵) + 2번째 방출까지
      // 25프레임 = 53프레임이면 충분하지만, 여유 있게 70프레임 흘려보낸다.
      await _feed(src, 0.2, 70);

      expect(emitted.length, greaterThanOrEqualTo(2),
          reason: '조기 방출은 한 번으로 끝나지 않고 쿨다운을 두고 반복된다');

      // 첫 번째 발화: preRoll(무음)로 시작 → 앞부분이 조용함.
      expect(emitted[0].left.first.abs(), lessThan(0.01));
      // 두 번째부터는 쿨다운이 끝나자마자 재트리거되어 preRoll 버퍼를 채울
      // 시간이 없다 — 앞부분부터 이미 발화(0.2) 진폭.
      expect(emitted[1].left.first.abs(), greaterThan(0.1));

      await vad.stop();
      vad.dispose();
      await src.close();
    });

    test('조기 방출 직후 쿨다운 동안은 재트리거되지 않는다', () async {
      const cooldownMs = 200; // = 10프레임
      final vad = VoiceActivityDetector(cooldownMs: cooldownMs);
      final src = StreamController<RawAudioChunk>();
      final emitted = <CapturedUtterance>[];
      final speaking = <bool>[];
      vad.start(src.stream, earlyEmitSamples: earlyEmitSamples);
      vad.utteranceStream.listen(emitted.add);
      vad.isSpeakingStream.listen(speaking.add);

      await _feed(src, 0.0, 10);

      // 첫 조기 방출이 나올 때까지 한 프레임씩 계속 먹인다.
      while (emitted.isEmpty) {
        await _feed(src, 0.2);
      }
      expect(speaking, [true, false]);

      // 쿨다운(10프레임) 동안은 계속 큰 소리를 먹여도 재트리거되면 안 된다
      // — 마지막 한 프레임(정확히 10번째 스킵 프레임)까지 포함해서 확인.
      await _feed(src, 0.2, 10);
      expect(speaking, [true, false],
          reason: '쿨다운이 끝나기 전이라 재트리거되면 안 됨');

      // 쿨다운이 끝난 다음 프레임에서는 여전히 크므로 곧바로 재트리거된다.
      await _feed(src, 0.2, 1);
      expect(speaking, [true, false, true],
          reason: '쿨다운이 끝난 뒤엔 재트리거돼야 함');

      await vad.stop();
      vad.dispose();
      await src.close();
    });
  });
}
