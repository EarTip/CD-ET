import 'dart:convert';

import 'sound_classifier.dart';

/// thresholds.json 의 `single.thresholds` 를 클래스별 임계값으로 읽는다.
/// 노트북(tflite.ipynb)의 임계값 계산 셀이 model.tflite 와 함께 내보내는 파일이다.
///
/// 파일에 없는 클래스나 0~1 범위를 벗어난 값은 [fallback] 값을 그대로 쓴다.
/// JSON 형식이 잘못됐으면 [FormatException] 을 던진다.
Map<SoundClass, double> parseSingleLabelThresholds(
  String source,
  Map<SoundClass, double> fallback,
) {
  final root = jsonDecode(source);
  final single = root is Map ? root['single'] : null;
  final values = single is Map ? single['thresholds'] : null;
  if (values is! Map) {
    throw const FormatException('thresholds.json 에 single.thresholds 가 없습니다');
  }

  final result = Map<SoundClass, double>.of(fallback);
  for (final c in SoundClass.values) {
    if (c == SoundClass.background) continue;
    final v = values[c.name];
    if (v is num && v >= 0 && v <= 1) result[c] = v.toDouble();
  }
  return result;
}
