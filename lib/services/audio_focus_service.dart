import 'dart:async';
import 'dart:io';
import 'package:audio_session/audio_session.dart';

class AudioFocusService {
  bool _initialized = false;
  bool _isFocused = false;
  static const Duration _restoreDelay = Duration(milliseconds: 800);
  Timer? _restoreTimer;
  AudioSession? _session;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _session = await AudioSession.instance;
    await _session!.configure(AudioSessionConfiguration(
      // iOS: 덕킹 시 카테고리 설정
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.mixWithOthers |
          AVAudioSessionCategoryOptions.duckOthers |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      // Android: 덕킹만, 일시정지 안 함
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: false,
    ));
    print('✅ AudioFocusService init 완료');
  }

  Future<void> requestFocus() async {
    if (_isFocused) {
      _restoreTimer?.cancel();
      return;
    }
    _isFocused = true;
    await _session?.setActive(true);
  }

  Future<void> releaseFocus({Duration delay = _restoreDelay}) async {
    if (!_isFocused) return;
    _restoreTimer?.cancel();
    _restoreTimer = Timer(delay, () async {
      _isFocused = false;
      if (Platform.isAndroid) await _session?.setActive(false);
    });
  }

  Future<void> forceRelease() async {
    _restoreTimer?.cancel();
    _isFocused = false;
    await _session?.setActive(false);
  }

  bool get isFocused => _isFocused;
  bool get isInitialized => _initialized;

  Future<void> dispose() async {
    await forceRelease();
  }
}