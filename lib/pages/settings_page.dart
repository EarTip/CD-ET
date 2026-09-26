import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/sound_detector.dart';

const _kBlue      = Color(0xFF5B9CF6);
const _kTextDark  = Color(0xFF1A1A2E);
const _kTextGrey  = Color(0xFF8A8FA8);
const _kDisabled  = Color(0xFFB0B0B0);

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static IconData iconFor(DetectedSound sound) => switch (sound) {
        DetectedSound.horn  => Icons.car_crash_outlined,
        DetectedSound.siren => Icons.emergency_outlined,
        DetectedSound.brake => Icons.directions_car_outlined,
        DetectedSound.none  => Icons.help_outline,
      };

  static IconData iconForChannel(AlertChannel channel) => switch (channel) {
        AlertChannel.haptic  => Icons.vibration,
        AlertChannel.voice   => Icons.record_voice_over_outlined,
        AlertChannel.preview => Icons.notifications_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F5FA),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  buildHeader(context),
                  const SizedBox(height: 28),

                  const Text('감지 항목', style: sectionTitle),
                  const SizedBox(height: 4),
                  const Text('끄면 해당 소리는 감지하지 않아요', style: sectionCaption),
                  const SizedBox(height: 12),
                  _Card(
                    children: [
                      for (final sound in SettingsService.detectableSounds)
                        _SwitchRow(
                          icon: iconFor(sound),
                          label: sound.label,
                          value: settings.isSoundEnabled(sound),
                          onChanged: (v) => settings.setSoundEnabled(sound, v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  const Text('알림 방식', style: sectionTitle),
                  const SizedBox(height: 4),
                  Text(
                    settings.alertChannels.isEmpty
                        ? '선택된 방식이 없어요 — 감지되어도 알려드리지 않아요'
                        : '소리를 감지했을 때 어떻게 알려드릴까요?',
                    style: settings.alertChannels.isEmpty ? sectionWarning : sectionCaption,
                  ),
                  const SizedBox(height: 12),
                  _Card(
                    children: [
                      for (final channel in AlertChannel.values)
                        _SwitchRow(
                          icon: iconForChannel(channel),
                          label: channel.label,
                          description: channel.description,
                          value: settings.isChannelEnabled(channel),
                          onChanged: (v) => settings.setChannelEnabled(channel, v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  const Text('감지 조건', style: sectionTitle),
                  const SizedBox(height: 12),
                  _Card(
                    children: [
                      _SwitchRow(
                        icon: Icons.headphones_outlined,
                        label: '이어폰 연결 시에만 감지',
                        description: '이어폰이 분리되면 마이크를 자동으로 꺼요',
                        value: settings.earphoneOnly,
                        onChanged: settings.setEarphoneOnly,
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static const sectionTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: _kTextDark,
  );

  static const sectionCaption = TextStyle(fontSize: 12, color: _kTextGrey);
  static const sectionWarning = TextStyle(fontSize: 12, color: Color(0xFFFF9500), fontWeight: FontWeight.w600);

  Widget buildHeader(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded, color: _kBlue, size: 20),
          ),
        ),
        const SizedBox(width: 16),
        const Text(
          '설정',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: _kTextDark),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 66, color: Color(0xFFF0F2F7)),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  const _LeadingIcon({required this.icon, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: active ? _kBlue.withValues(alpha: 0.12) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: active ? _kBlue : _kDisabled, size: 20),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _LeadingIcon(icon: icon, active: value),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: value ? _kTextDark : _kDisabled,
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(description!, style: const TextStyle(fontSize: 11, color: _kTextGrey)),
                  ],
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: _kBlue,
            ),
          ],
        ),
      ),
    );
  }
}
