# EarTips

노이즈 캔슬링 이어폰 사용자와 청각장애인이 경적·사이렌·급제동음·자전거 벨 같은 위험 소리를 놓치지 않도록,
스마트폰에서 온디바이스로 소리를 인식해 햅틱·음성·알림으로 알려 주는 Flutter 앱입니다.

2026 캡스톤 4분반 2조 · 팀 귀띔

---

### 배경

노이즈 캔슬링 이어폰은 편리하지만 도로 위 위험 소리까지 막아 보행자 안전을 위협할 수 있고,
청각장애인은 이런 소리를 듣기 어렵습니다. EarTips는 스마트폰 마이크로 주변 소리를 실시간 분석해
위험 소리를 감지하고 방향과 함께 즉시 사용자에게 전달합니다.

### 핵심 기능

- **온디바이스 위험음 감지**: 서버 없이 폰에서 경적 · 사이렌 · 급제동음 · 자전거 벨을 실시간 분류 (YAMNet + 분류 헤드)
- **오탐 억제**: 클래스별 임계값, 연속 감지 확인, 무음 구간 스킵으로 생활 소음에 울리지 않게
- **방향 추정**: 스테레오 마이크의 좌우 도착 시간차(TDOA)로 소리가 오는 방향을 함께 안내
- **상황 인지**: 걷는 중 · 실외일 때만 마이크를 켜고, 횡단보도 · 큰 도로 근처에서는 민감도를 높임
- **다중 채널 알림**: 소리별 햅틱 패턴, 화면 알림, 음악을 줄이고 들려주는 TTS 음성 안내

### 아키텍처

```
[SoundDetector]
  마이크 입력 ─ 16kHz 스테레오, 0.975초 창 / 0.25초 간격
      │
      ▼
  YAMNet + 분류 헤드 ─ RMS 무음 스킵 → TFLite 추론(5클래스) → 클래스별 임계값 · 연속 감지
      │ 위험음 확정
      ▼
  TDOA ─ 좌우 도착 시간차(GCC-PHAT) + 폰 자세 → 정면 / 후방 / 측면
      │
      │ 종류 + 방향              ▲ 민감도 조정 · 알림음 감지 억제
      ▼                          │
[SoundManager]
  ├─ 마이크 제어 ─ 보행(가속도계) · 실내외(YAMNet 배경음 + GPS) · 이어폰 연결
  ├─ 민감도 ───── 지오펜싱 (OSM: 횡단보도 · 주요 도로)
  └─ 알림 제어 ── 쿨다운 · 알림 채널 선택 · 감지 기록 저장(SQLite)
      │
      ├──► 햅틱 진동 ─ 유형별 패턴 (Kotlin / Swift 네이티브)
      ├──► 화면 알림 ─ 종류 · 방향 표시
      └──► TTS 음성 ─ 오디오 덕킹
```

### 기술 스택

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge&logo=dart&logoColor=white)
![TensorFlow Lite](https://img.shields.io/badge/TensorFlow_Lite-FF6F00?style=for-the-badge&logo=tensorflow&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)

- **AI**: YAMNet 임베딩 + 분류 헤드 (TensorFlow Lite, 온디바이스 추론)
- **Native**: Kotlin (Android 햅틱 · TTS) / Swift (iOS 햅틱 · 위젯)

### 팀 구성 및 담당

| 이름 | 담당 |
|---|---|
| 강희진 | 햅틱·TTS·백그라운드 알림, 오디오 포커스 처리 |
| 김현정 | 프로젝트 세팅·Firebase 연동, 화면 UI, TDOA 방향 추정, 이동 상태·위치 기반 민감도 조정 |
| 최정연 | YAMNet 기반 위험음 분류 |

### 프로젝트 구조

```
lib/
├── models/      # 분류 모델 추론, 임계값, 감지 기록 모델
├── pages/       # 홈 · 통계 · 설정 화면
├── services/    # 소리 감지 · 방향 추정 · 상황 인지 · 알림
└── widgets/     # 화면 공용 위젯
assets/models/   # TFLite 모델, thresholds.json
tools/           # 임계값 계산, 오탐율 측정 (ESC-50)
android/, ios/   # 햅틱 · TTS 네이티브 채널, 홈 화면 위젯
test/            # 단위 테스트
```

### 시작하기

```bash
flutter pub get
cd ios && pod install && cd ..   # iOS
flutter run
```

모델 파일은 `assets/models/`에 포함돼 있습니다.
분류 모델을 교체하면 `tools/threshold_cell.py`로 `thresholds.json`도 다시 만들어야 합니다.

