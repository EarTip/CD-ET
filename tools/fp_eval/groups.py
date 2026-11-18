import sys, csv, json, numpy as np
sys.argv=['', '/home/claude/data/ESC-50','win.npz','/dev/null']
exec(open('simulate.py').read().split("res = {")[0])
tgt={m['filename']:int(m['target']) for m in csv.DictReader(open(f'{ESC}/meta/esc50.csv'))}
G=['동물','자연·물 소리','사람(비음성)','실내·생활음','실외·도시 소음']
out={}
for gi,g in enumerate(G):
    fs=[f for f in neg if tgt[f]//10==gi]
    ev={f:simulate(data[f]) for f in fs}
    n=sum(1 for e in ev.values() if e)
    from collections import Counter
    out[g]=dict(n=len(fs),fp=n,fpr=round(n/len(fs),3),pred=dict(Counter(c for e in ev.values() for c in e)))
print(json.dumps(out,ensure_ascii=False,indent=1))
# 확신도: RMS 통과 창 중 위험음 판정 창의 top 확률 분포
tops=[];bgtop=0;n=0
for f in neg:
    for r in data[f]:
        if r[0]<MIN_RMS: continue
        n+=1; p=r[1:6]; t=int(np.argmax(p))
        if t==4: bgtop+=1
        else: tops.append(p[t])
tops=np.array(tops)
print('windows',n,'bg top',bgtop/n,'danger top pcts',np.percentile(tops,[10,25,50,75,90]).round(3), '>=0.9:',(tops>=0.9).mean().round(3))
# 사람 비교: 양성 창 확신도
