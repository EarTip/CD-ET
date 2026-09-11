# EarTips

노이즈 캔슬링 이어폰 사용 중에도 경적·사이렌·급제동 같은 위험 소리를 놓치지 않도록,
온디바이스 음향 인식과 상황 인지 알림으로 사용자의 안전을 보조하는 Flutter 앱입니다.

2026 캡스톤 4분반 2조

---

### 배경

노이즈 캔슬링 이어폰은 편의를 제공하지만 도로 위 위험 소리(자동차 경적, 사이렌, 급제동음)를
차단해 보행자 안전을 위협할 수 있습니다. EarTips는 스마트폰 마이크로 주변 소리를 실시간 분석해,
위험 상황을 감지하면 햅틱·음성·알림으로 즉시 사용자에게 전달합니다.

### 핵심 기능

- **온디바이스 소리 감지**: YAMNet(TFLite) 기반으로 경적/사이렌/브레이크음을 실시간 분류
- **방향 추정 (TDOA)**: 스테레오 마이크 입력의 도착시간차를 이용해 소리가 정면/후방/측면 중 어디서 오는지 추정
- **위치 기반 민감도 조정**: 횡단보도·주요 도로 인접 시 감지 민감도를 자동으로 높이는 지오펜싱
- **이동 상태 인지**: 가속도계로 이동/정지 상태를 판별해 불필요한 알림을 줄임
- **다중 채널 알림**: 위험 유형별로 구분되는 커스텀 햅틱 패턴, TTS 음성 안내, 백그라운드 알림을 동시 지원
- **오디오 포커스 관리**: 음악/통화 등 다른 오디오 재생 중에도 TTS 안내가 자연스럽게 개입(ducking)되도록 처리
- **개인화 이름 호출 감지**: 사용자가 등록한 이름과 실시간 발화를 비교해, 누군가 이름을 부르는 상황을 인식

### 아키텍처

```
Mic Input (Stereo)
      │
      ├───────────────────────────────┐
      ▼                                ▼
SoundDetector (YAMNet TFLite)   VoiceActivityDetector
      │  분류: horn / siren / brake     │  발화 구간(onset/offset) 검출
      ▼                                ▼
TdoaAnalyzer ──► 방향 추정        NameCallDetector
      │                           (화자 임베딩 vs 등록된 EnrollmentStore)
      │                                │
      ▼                                │
SoundManager (중앙 조율) ◄────────────────┘
   ├─ ActivityService     (이동/정지 상태)
   ├─ GeofenceService     (횡단보도/도로 민감도)
   ├─ HapticService        ──► Android(Kotlin) / iOS(Swift) 네이티브 채널
   ├─ TtsService            ──► AudioFocusService (오디오 덕킹)
   └─ NotificationService   ──► 백그라운드 알림
```

### 기술 스택

`Flutter` `Dart` `TensorFlow Lite (YAMNet)` `Firebase (Core / Firestore / Analytics)`
`Kotlin (Android Native)` `Swift (iOS Native)`

주요 패키지: `tflite_flutter`, `record`, `vibration`, `flutter_tts`, `flutter_local_notifications`,
`audio_session`, `sensors_plus`, `geolocator`, `flutter_foreground_task`, `fftea`, `path_provider`

### 팀 구성 및 담당
 
| 이름 | 담당 |
|---|---|
| 강희진 | 햅틱·TTS·백그라운드 알림, 오디오 포커스 처리, 이름 호출 감지 파이프라인 |
| 김현정 | 프로젝트 세팅·Firebase 연동, 화면 UI, TDOA 방향 추정, 이동 상태·위치 기반 민감도 조정 |
| 최정연 | YAMNet 기반 위험음 분류|

### 프로젝트 구조

```
lib/
├── main.dart
├── pages/
│   ├── splash_page.dart
│   ├── home_page.dart
│   └── profile_page.dart        # 이름 등록 화면
├── services/
│   ├── sound_detector.dart      # YAMNet 기반 소리 감지
│   ├── tdoa_analyzer.dart       # 방향 추정
│   ├── sound_manager.dart       # 전체 흐름 조율
│   ├── activity_service.dart    # 이동 상태 감지
│   ├── geofence_service.dart    # 위치 기반 민감도
│   ├── haptic.dart              # 햅틱 알림
│   ├── tts.dart                 # 음성 알림
│   ├── audio_focus_service.dart # 오디오 포커스 관리
│   ├── notification.dart        # 백그라운드 알림
│   ├── voice_activity_detector.dart # 발화 구간 검출 (이름 감지용)
│   ├── mel_frontend.dart        # log-mel 프론트엔드 (이름 감지용)
│   ├── name_embedder.dart       # 화자 임베딩 (이름 감지용, 백엔드 모델 미확정)
│   ├── name_call_detector.dart  # 이름 호출 감지 오케스트레이션
│   └── enrollment_store.dart    # 등록된 목소리 임베딩 로컬 저장(기기 내부 전용)
└── widgets/
    ├── main_card.dart
    ├── alert_grid.dart
    └── recent_list.dart
```

### 시작하기

```bash
flutter pub get
flutter run
```

`assets/models/yamnet.tflite` 모델 파일이 필요합니다.
(이름 호출 감지용 화자 임베딩 모델은 아직 확정 전이라 별도 asset은 포함돼 있지 않습니다.)

---

> 이 저장소는 팀 프로젝트 레포입니다. 브랜치별 작업 내역은 `feat/*` 브랜치를 참고하세요.
