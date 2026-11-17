"""#37 전후 비교: 같은 win.npz 에 임계값·연속확인 설정만 바꿔 앱 판정 로직(simulate.py)을 돌린다."""
import sys, json, numpy as np
from collections import Counter
ESC, NPZ, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
src = open('simulate.py', encoding='utf-8').read().split("res = {")[0]
g = {}
sys.argv = ['', ESC, NPZ, '/dev/null']
exec(src, g)
meta, data, neg, pos, POSITIVE, simulate = g['meta'], g['data'], g['neg'], g['pos'], g['POSITIVE'], g['simulate']
tgt = {}
import csv
for m in csv.DictReader(open(f'{ESC}/meta/esc50.csv')): tgt[m['filename']] = int(m['target'])
GROUPS = ['동물', '자연·물 소리', '사람(비음성)', '실내·생활음', '실외·도시 소음']

SETTINGS = {
    '변경 전 (0.5/0.5/0.5/0.7, 연속 2/2/2/3)': ({'horn': .5, 'siren': .5, 'brake': .5, 'bicycle': .7}, {'horn': 2, 'siren': 2, 'brake': 2, 'bicycle': 3}),
    '#37 반영 (0.51/0.43/0.49/0.84, 연속 2/2/2/3)':           ({'horn': .51, 'siren': .43, 'brake': .49, 'bicycle': .84}, {'horn': 2, 'siren': 2, 'brake': 2, 'bicycle': 3}),
    '참고: #37 임계값 + bicycle 연속 2회 (채택 안 함, 연속 2/2/2/2)': ({'horn': .51, 'siren': .43, 'brake': .49, 'bicycle': .84}, {'horn': 2, 'siren': 2, 'brake': 2, 'bicycle': 2}),
}
res = {'n_neg_clips': len(neg), 'n_pos_clips': len(pos), 'settings': {}}
for name, (T, R) in SETTINGS.items():
    g['BASE_T'].clear(); g['BASE_T'].update(T)
    g['REQ'].clear(); g['REQ'].update(R)
    row = {}
    for label, kw in {'app': {}, 'crosswalk': {'offset': -0.2}}.items():
        ev = {f: simulate(data[f], **kw) for f in neg}
        n_fp = sum(1 for e in ev.values() if e)
        rec = {k: sum(POSITIVE[k] in simulate(data[f], **kw) for f in pos if meta[f] == k) / 40 for k in POSITIVE}
        d = dict(clip_fpr=round(n_fp / len(neg), 4), n_fp_clips=n_fp,
                 by_pred=dict(Counter(c for e in ev.values() for c in e)), recall=rec)
        if label == 'app':
            d['by_group'] = {gname: round(sum(1 for f in neg if tgt[f] // 10 == gi and ev[f]) / sum(1 for f in neg if tgt[f] // 10 == gi), 3)
                             for gi, gname in enumerate(GROUPS)}
        row[label] = d
    res['settings'][name] = row
    a, c = row['app'], row['crosswalk']
    print(f"{name}\n  앱 기본 {a['clip_fpr']*100:.1f}% ({a['n_fp_clips']}/{len(neg)})  횡단보도 {c['clip_fpr']*100:.1f}%"
          f"  탐지 horn {a['recall']['car_horn']*100:.1f}% siren {a['recall']['siren']*100:.1f}%\n  알림종류 {a['by_pred']}\n  그룹 {a['by_group']}")
json.dump(res, open(OUT, 'w'), ensure_ascii=False, indent=1)
