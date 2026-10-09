import json, sys, os
from collections import Counter
d = sys.argv[1]
a = json.load(open(os.path.join(d,'analysis.json')))
props = a['proposals']
out = {}
out['total'] = len(props)
out['by_kind'] = dict(Counter(p['kind'] for p in props))
out['titles'] = sorted(p['title'] for p in props)
ev = [len(p.get('evidence',[])) for p in props]
out['evidence_total'] = sum(ev)
out['evidence_zero'] = sum(1 for e in ev if e==0)
out['warnings'] = a.get('warnings',[])
out['decisions'] = len(a.get('decisions',[]))
# duplicates: same normalized title or shared activation keys across characters
chars = [p for p in props if p['kind']=='character']
names = Counter()
for p in chars:
    for k in p.get('activationKeys',[]): names[k]+=1
out['shared_activation_keys'] = {k:v for k,v in names.items() if v>1}
batches = sorted(os.listdir(os.path.join(d,'analysis','batches'))) if os.path.isdir(os.path.join(d,'analysis','batches')) else []
out['batches'] = len(batches)
bw = []
for b in batches:
    bd = json.load(open(os.path.join(d,'analysis','batches',b)))
    bw += bd.get('warnings',[])
out['batch_warnings'] = bw
j = json.load(open(os.path.join(d,'job.json')))
out['executor'] = j.get('executorVersion')
out['duration_sec'] = None
try:
    from datetime import datetime
    fmt='%Y-%m-%dT%H:%M:%SZ'
    out['duration_sec'] = (datetime.strptime(j['updatedAt'],fmt)-datetime.strptime(j['createdAt'],fmt)).total_seconds()
except Exception: pass
print(json.dumps(out, ensure_ascii=False, indent=1))
