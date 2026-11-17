import 'package:eartips/models/sound_classifier.dart';
import 'package:eartips/models/sound_thresholds.dart';
import 'package:flutter_test/flutter_test.dart';

const _fallback = {
  SoundClass.horn: 0.5,
  SoundClass.siren: 0.5,
  SoundClass.brake: 0.5,
  SoundClass.bicycle: 0.7,
};

void main() {
  test('single.thresholds 값으로 덮어쓴다', () {
    const json = '{"single": {"thresholds": '
        '{"horn": 0.51, "siren": 0.43, "brake": 0.49, "bicycle": 0.84}}}';
    expect(parseSingleLabelThresholds(json, _fallback), {
      SoundClass.horn: 0.51,
      SoundClass.siren: 0.43,
      SoundClass.brake: 0.49,
      SoundClass.bicycle: 0.84,
    });
  });

  test('빠진 클래스와 범위 밖 값은 기본값을 유지한다', () {
    const json = '{"single": {"thresholds": {"horn": 0.6, "siren": 1.5, "brake": "x"}}}';
    expect(parseSingleLabelThresholds(json, _fallback), {
      SoundClass.horn: 0.6,
      SoundClass.siren: 0.5,
      SoundClass.brake: 0.5,
      SoundClass.bicycle: 0.7,
    });
  });

  test('single.thresholds 가 없으면 FormatException', () {
    expect(() => parseSingleLabelThresholds('{"version": 1}', _fallback),
        throwsFormatException);
    expect(() => parseSingleLabelThresholds('not json', _fallback),
        throwsFormatException);
  });
}
