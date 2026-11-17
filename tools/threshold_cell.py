# ===== 클래스별 임계값 계산 → thresholds.json 저장 =====
# - 학습은 하지 않는다 (model_v4.keras 를 불러와서 평가만)
# - 셀 3 을 다시 돌리면 모델이 재학습·덮어써지니까, 런타임이 끊겼으면 이 셀만 실행할 것
import os, json, random, hashlib, datetime
import numpy as np
import tensorflow as tf
import tensorflow_hub as hub
import librosa
from sklearn.model_selection import train_test_split
from google.colab import drive

drive.mount("/content/drive")

DATASET_DIR  = "/content/drive/MyDrive/dataset"
MODEL_KERAS  = f"{DATASET_DIR}/model_v4.keras"
MODEL_TFLITE = f"{DATASET_DIR}/model_v4.tflite"
OUT_PATH     = "/content/drive/MyDrive/thresholds.json"  # dataset 폴더는 보기 권한뿐이라 내 드라이브에 저장
APP_MODEL_MD5 = "61bb344a99eb755787fc4b3c57d155fb"  # 앱 assets/models/model.tflite (2026-11-17 기준)

CLASSES = ["horn", "siren", "brake", "bicycle", "background"]
MAX_PER_CLASS = {"horn": 400, "siren": 400, "brake": 400, "bicycle": 400, "background": 800}
DANGER = {"horn", "siren", "brake"}
# 위험 소리는 놓치지 않는 쪽(재현율 가중, beta=2), bicycle 은 오탐 줄이는 쪽(정밀도 가중, beta=0.5)
BETA = {c: (2.0 if c in DANGER else 0.5) for c in CLASSES if c != "background"}
GRID = np.round(np.arange(0.20, 0.951, 0.01), 2)
T_MIN, T_MAX = 0.25, 0.90  # 극단값 방지

if not os.path.isdir(f"{DATASET_DIR}/augmented/horn"):
    raise SystemExit("내 드라이브에 dataset 폴더가 없음 → 드라이브에서 공유받은 dataset 폴더 우클릭 > 정리 > 바로가기 추가 > 내 드라이브, 그 다음 다시 실행")

def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()

# ── 1. 셀 3 과 같은 test 셋 준비 (런타임에 남아 있으면 재사용) ──
if "X_emb" in globals() and "y" in globals() and len(X_emb) == len(y):
    print("런타임에 남아 있는 임베딩 재사용")
    X_all, y_all = X_emb, y
else:
    print("임베딩 다시 추출 (셀 3 과 같은 파일·순서)")
    _yamnet = hub.load("https://tfhub.dev/google/yamnet/1")

    def _load_audio(path):
        a, _ = librosa.load(path, sr=16000, mono=True)
        if len(a) < 15600:
            a = np.pad(a, (0, 15600 - len(a)))
        return a[:15600]

    def _pick_files(folder, n):
        files = [f for f in os.listdir(folder) if f.endswith(".wav")]
        priority = sorted(f for f in files if f.startswith("0_"))
        rest = sorted(f for f in files if not f.startswith("0_"))
        random.Random(42).shuffle(rest)
        return (priority + rest)[:n]

    embs, labels = [], []
    for idx, cls in enumerate(CLASSES):
        folder = os.path.join(DATASET_DIR, "augmented", cls)
        files = _pick_files(folder, MAX_PER_CLASS[cls])
        print(f"  {cls}: {len(files)}개")
        for fname in files:
            try:
                _, emb, _ = _yamnet(_load_audio(os.path.join(folder, fname)))
                embs.append(np.mean(emb.numpy(), axis=0))
                labels.append(idx)
            except Exception as e:
                print(f"  에러: {fname} - {e}")
    X_all, y_all = np.array(embs), np.array(labels)

if len(X_all) != 2304:
    print(f"⚠️  샘플 수 {len(X_all)}개 — v4 학습 때(2304개)와 달라서 test 셋이 다를 수 있음")
_, X_te, _, y_te = train_test_split(X_all, y_all, test_size=0.2, random_state=42, stratify=y_all)
print(f"test 셋 {len(X_te)}개")

# ── 2. 확률 예측 ──
model_v4 = tf.keras.models.load_model(MODEL_KERAS)
probs = model_v4.predict(X_te, verbose=0)

# ── 3. 클래스별 임계값 탐색 (앱 단일 라벨 규칙: top-1 == c 이고 p_c >= t) ──
def metrics_at(c, t):
    pred = (probs.argmax(1) == c) & (probs[:, c] >= t)
    pos = (y_te == c)
    tp = int((pred & pos).sum()); fp = int((pred & ~pos).sum()); fn = int((~pred & pos).sum())
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    return p, r

def fbeta(p, r, b):
    return 0.0 if p + r == 0 else (1 + b * b) * p * r / (b * b * p + r)

thresholds, report = {}, {}
for c, name in enumerate(CLASSES):
    if name == "background":
        continue
    best = None
    for t in GRID:
        p, r = metrics_at(c, t)
        score = fbeta(p, r, BETA[name])
        if best is None or score > best[0] or (score == best[0] and p > best[2]):
            best = (score, float(t), p, r)
    t = float(np.clip(best[1], T_MIN, T_MAX))
    p, r = metrics_at(c, t)
    thresholds[name] = round(t, 2)
    report[name] = {"precision": round(p, 3), "recall": round(r, 3), "beta": BETA[name]}
    p0, r0 = metrics_at(c, 0.0)  # 임계값 없이 argmax 만 썼을 때
    print(f"{name:8s} t={t:.2f}  precision {p:.2f}  recall {r:.2f}   (argmax만: {p0:.2f} / {r0:.2f})")

# ── 4. 저장 ──
model_md5 = md5(MODEL_TFLITE) if os.path.exists(MODEL_TFLITE) else None
print(f"\nmodel_v4.tflite md5 = {model_md5}")
print("앱 model.tflite 와 " + ("같은 모델 ✅" if model_md5 == APP_MODEL_MD5 else "다른 모델 ⚠️  — 앱에 넣기 전에 확인 필요"))

out = {
    "version": 1,
    "created": datetime.datetime.now().isoformat(timespec="seconds"),
    "single": {
        "model": os.path.basename(MODEL_TFLITE),
        "model_md5": model_md5,
        "rule": "top1 == class and prob >= threshold",
        "thresholds": thresholds,
        "metrics": report,
    },
    "method": f"test 셋(20%, random_state=42)에서 F-beta 최대 지점, 범위 {T_MIN}~{T_MAX}",
    "warning": "증강 후 랜덤 분할이라 수치가 낙관적일 수 있음. 실기기 로그로 재보정 권장",
}
with open(OUT_PATH, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"\n저장 완료 → {OUT_PATH}")
print(json.dumps(thresholds, indent=2))
