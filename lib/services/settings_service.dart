import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sound_detector.dart';

/// 감지 시 사용할 알림 채널 (복수 선택 가능)
enum AlertChannel { haptic, voice, preview }

extension AlertChannelInfo on AlertChannel {
  String get label => switch (this) {
        AlertChannel.haptic  => '햅틱',
        AlertChannel.voice   => '음성알림',
        AlertChannel.preview => '미리보기',
      };

  String get description => switch (this) {
        AlertChannel.haptic  => '진동 패턴으로 알려줘요',
        AlertChannel.voice   => '음성으로 읽어줘요',
        AlertChannel.preview => '알림 미리보기로 알려줘요',
      };
}

extension DetectedSoundInfo on DetectedSound {
  String get label => switch (this) {
        DetectedSound.horn  => '경적',
        DetectedSound.siren => '사이렌',
        DetectedSound.brake => '급브레이크',
        DetectedSound.none  => '없음',
      };
}

/// 앱 설정 (SharedPreferences 영속화, 싱글턴)
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _keySoundPrefix   = 'sound_enabled_';
  static const _keyAlertChannels = 'alert_channels';
  static const _keyEarphoneOnly  = 'earphone_only';

  static const detectableSounds = [
    DetectedSound.horn,
    DetectedSound.siren,
    DetectedSound.brake,
  ];

  SharedPreferences? _prefs;
  bool _loaded = false;

  final Map<DetectedSound, bool> _soundEnabled = {
    for (final s in detectableSounds) s: true,
  };
  Set<AlertChannel> _alertChannels = {...AlertChannel.values};
  bool _earphoneOnly = true;

  bool get isLoaded => _loaded;
  Set<AlertChannel> get alertChannels => Set.unmodifiable(_alertChannels);
  bool get earphoneOnly => _earphoneOnly;

  bool isSoundEnabled(DetectedSound sound) => _soundEnabled[sound] ?? false;
  bool isChannelEnabled(AlertChannel channel) => _alertChannels.contains(channel);

  Future<void> load() async {
    if (_loaded) return;
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;

    for (final s in detectableSounds) {
      _soundEnabled[s] = p.getBool('$_keySoundPrefix${s.name}') ?? true;
    }
    final channelNames = p.getStringList(_keyAlertChannels);
    if (channelNames != null) {
      _alertChannels = {
        for (final c in AlertChannel.values)
          if (channelNames.contains(c.name)) c,
      };
    }
    _earphoneOnly = p.getBool(_keyEarphoneOnly) ?? true;

    _loaded = true;
    notifyListeners();
    debugPrint('⚙️ 설정 로드: sounds=$_soundEnabled channels=$_alertChannels earphoneOnly=$_earphoneOnly');
  }

  Future<void> setSoundEnabled(DetectedSound sound, bool enabled) async {
    if (_soundEnabled[sound] == enabled) return;
    _soundEnabled[sound] = enabled;
    notifyListeners();
    await _prefs?.setBool('$_keySoundPrefix${sound.name}', enabled);
  }

  Future<void> setChannelEnabled(AlertChannel channel, bool enabled) async {
    if (_alertChannels.contains(channel) == enabled) return;
    if (enabled) {
      _alertChannels.add(channel);
    } else {
      _alertChannels.remove(channel);
    }
    notifyListeners();
    await _prefs?.setStringList(
      _keyAlertChannels,
      [for (final c in _alertChannels) c.name],
    );
  }

  Future<void> setEarphoneOnly(bool value) async {
    if (_earphoneOnly == value) return;
    _earphoneOnly = value;
    notifyListeners();
    await _prefs?.setBool(_keyEarphoneOnly, value);
  }
}
