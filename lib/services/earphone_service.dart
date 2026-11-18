// ignore_for_file: experimental_member_use
import 'dart:async';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 이어폰(유선/블루투스) 연결 여부 감시
class EarphoneService {
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<Set<AudioDevice>>? _deviceSubscription;
  bool _connected = false;

  static const _earphoneTypes = {
    AudioDeviceType.wiredHeadset,
    AudioDeviceType.wiredHeadphones,
    AudioDeviceType.bluetoothA2dp,
    AudioDeviceType.bluetoothSco,
    AudioDeviceType.bluetoothLe,
    AudioDeviceType.usbAudio,
    AudioDeviceType.hearingAid,
  };

  /// 연결 상태가 바뀔 때마다 emit
  Stream<bool> get connectionStream => _controller.stream;
  bool get isConnected => _connected;

  Future<void> start() async {
    if (_deviceSubscription != null) return;
    try {
      final session = await AudioSession.instance;
      _update(await session.getDevices(includeInputs: false));
      _deviceSubscription = session.devicesStream.listen(_update);
    } catch (e) {
      // 기기 조회 실패(구형 Android 등) 시 감지를 막지 않도록 연결된 것으로 간주
      debugPrint('❌ 오디오 기기 조회 실패: $e');
      _connected = true;
    }
  }

  void _update(Set<AudioDevice> devices) {
    final connected = devices.any((d) => d.isOutput && _earphoneTypes.contains(d.type));
    if (connected == _connected) return;
    _connected = connected;
    debugPrint(connected ? '🎧 이어폰 연결됨' : '🎧 이어폰 분리됨');
    if (!_controller.isClosed) _controller.add(connected);
  }

  void stop() {
    _deviceSubscription?.cancel();
    _deviceSubscription = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
