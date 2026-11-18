"""win.npz(창별 RMS·확률)에 앱의 판정 로직(sound_detector.dart)을 그대로 적용해 오탐을 센다."""
import sys, csv, json, numpy as np
from collections import Counter, defaultdict

ESC, NPZ, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
CLS = ['horn', 'siren', 'brake', 'bicycle', 'background']
BASE_T = {'horn': .5, 'siren': .5, 'brake': .5, 'bicycle': .7}
REQ = {'horn': 2, 'siren': 2, 'brake': 2, 'bicycle': 3}
MIN_RMS = 0.012
SUPPRESS_WIN = 12          # 3초 / 0.25초 hop
HOP_S, WIN_S = 0.25, 0.975
POSITIVE = {'car_horn': 'horn', 'siren': 'siren'}

meta = {m['filename']: m['category'] for m in csv.DictReader(open(f'{ESC}/meta/esc50.csv'))}
data = np.load(NPZ)

def hits_of(p, T, multi):
    if multi:
        return [c for i, c in enumerate(CLS[:4]) if p[i] >= T[c]]
    top = int(np.argmax(p))
    c = CLS[top]
    return [] if c == 'background' or p[top] < T[c] else [c]

def simulate(rows, offset=0.0, rms_gate=True, streak=True, multi=False):
    T = {c: min(max(v + offset, 0), 1) for c, v in BASE_T.items()}
    streaks = defaultdict(int)
    events, suppress_until = [], -1
    for i, r in enumerate(rows):
        if i <= suppress_until:
            streaks.clear(); continue
        if rms_gate and r[0] < MIN_RMS:
            streaks.clear(); continue
        p = r[6:11] if multi else r[1:6]
        h = hits_of(p, T, multi)
        for c in CLS[:4]:
            streaks[c] = streaks[c] + 1 if c in h else 0
        conf = [c for c in h if streaks[c] >= (REQ[c] if streak else 1)]
        if conf:
            events += conf
            suppress_until = i + SUPPRESS_WIN
            streaks.clear()
    return events

def window_stats(fns, offset=0.0, multi=False):
    """모델 단독(창 단위) 오탐: RMS 게이트를 통과한 창 중 위험음으로 판정된 비율"""
    T = {c: v + offset for c, v in BASE_T.items()}
    n = fp = 0
    for fn in fns:
        for r in data[fn]:
            if r[0] < MIN_RMS: continue
            n += 1
            fp += bool(hits_of(r[6:11] if multi else r[1:6], T, multi))
    return n, fp

neg = [f for f in data.files if meta[f] not in POSITIVE]
pos = [f for f in data.files if meta[f] in POSITIVE]
neg_hours = len(neg) * 5 / 3600

def clip_eval(fns, **kw):
    per_clip = {f: simulate(data[f], **kw) for f in fns}
    n_fp = sum(1 for e in per_clip.values() if e)
    n_ev = sum(len(e) for e in per_clip.values())
    return per_clip, n_fp, n_ev

res = {'n_neg_clips': len(neg), 'neg_hours': neg_hours, 'n_pos_clips': len(pos), 'configs': {}}

configs = {
    '모델 단독 (게이트·연속확인 없음)': dict(rms_gate=False, streak=False),
    '+ 무음 스킵': dict(rms_gate=True, streak=False),
    '+ 무음 스킵 + 연속 확인 (앱 기본)': dict(rms_gate=True, streak=True),
    '앱 기본, 횡단보도 민감도(-0.2)': dict(rms_gate=True, streak=True, offset=-0.2),
    '앱 기본, 다중 라벨 모델': dict(rms_gate=True, streak=True, multi=True),
}
for name, kw in configs.items():
    per_clip, n_fp, n_ev = clip_eval(neg, **kw)
    by_pred = Counter(c for e in per_clip.values() for c in e)
    by_cat = Counter(meta[f] for f, e in per_clip.items() if e)
    # 양성(car_horn, siren) 탐지율: 정답 클래스 알림이 1회 이상
    _, _, _ = None, None, None
    pos_ok = Counter()
    for f in pos:
        e = simulate(data[f], **kw)
        if POSITIVE[meta[f]] in e: pos_ok[meta[f]] += 1
    res['configs'][name] = dict(
        clip_fpr=n_fp / len(neg), n_fp_clips=n_fp, n_events=n_ev,
        fa_per_hour=n_ev / neg_hours, by_pred=dict(by_pred),
        by_category=dict(by_cat.most_common()),
        pos_recall={k: pos_ok[k] / 40 for k in POSITIVE},
    )

for name, kw in {'single': {}, 'single_crosswalk': dict(offset=-0.2), 'multi': dict(multi=True)}.items():
    n, fp = window_stats(neg, **kw)
    res[f'window_{name}'] = dict(n_windows=n, n_fp=fp, fpr=fp / n)

# 임계값 스윕 (앱 기본 파이프라인, 전 클래스 오프셋)
res['sweep'] = []
for off in np.round(np.arange(-0.3, 0.31, 0.05), 2):
    _, n_fp, n_ev = clip_eval(neg, offset=float(off))
    rec = {}
    for k in POSITIVE:
        fs = [f for f in pos if meta[f] == k]
        rec[k] = sum(POSITIVE[k] in simulate(data[f], offset=float(off)) for f in fs) / len(fs)
    res['sweep'].append(dict(offset=float(off), clip_fpr=n_fp / len(neg), fa_per_hour=n_ev / neg_hours, **{f'recall_{k}': v for k, v in rec.items()}))

json.dump(res, open(OUT, 'w'), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False, indent=1))
