import sys, json, re, bisect, unicodedata
from collections import Counter, defaultdict

sentences = json.load(open(sys.argv[1]))
asr_path, out_path = sys.argv[2], sys.argv[3]

def norm(w):
    w = w.lower().replace('ó','o')  # ASR rzadko myli ó/u, ale to tani kompromis
    w = re.sub(r'[^\w]', '', w)
    return w

# --- tokeny książki
B, Bs = [], []          # słowo, indeks zdania
for si, s in enumerate(sentences):
    for w in s['text'].split():
        n = norm(w)
        if n: B.append(n); Bs.append(si)
# --- tokeny ASR (frazy dzielone na słowa, czas po długości)
A, At = [], []
for line in open(asr_path, encoding='utf-8'):
    p = line.rstrip('\n').split('\t')
    if len(p) < 3: continue
    t0, t1, ws = float(p[0]), float(p[1]), p[2].split()
    tot = sum(len(w) for w in ws) or 1; acc = 0
    for w in ws:
        n = norm(w)
        a = t0 + (t1-t0)*acc/tot; acc += len(w); b = t0 + (t1-t0)*acc/tot
        if n: A.append(n); At.append((a, b))
print(f'book {len(B)} words, asr {len(A)} words')

def isnum(w): return w.isdigit()
def lev(a, b):
    if a == b: return 0
    if abs(len(a)-len(b)) > max(len(a), len(b))//2: return 99
    prev = list(range(len(b)+1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j]+1, cur[j-1]+1, prev[j-1]+(ca != cb)))
        prev = cur
    return prev[-1]
def sim(a, b):
    if a == b: return 1.0
    if isnum(a) or isnum(b): return 0.5
    if len(a) >= 4 and len(b) >= 4 and (a.startswith(b[:4]) or b.startswith(a[:4])): return 0.8  # odmiana
    d = lev(a, b); return max(0.0, 1 - d/max(len(a), len(b)))

def anchors(bi0, bi1, ai0, ai1, n):
    def grams(seq, lo, hi):
        c = Counter(); pos = {}
        for i in range(lo, hi-n+1):
            g = tuple(seq[i:i+n]); c[g] += 1; pos[g] = i
        return {g: pos[g] for g, k in c.items() if k == 1}
    gb, ga = grams(B, bi0, bi1), grams(A, ai0, ai1)
    pairs = sorted((gb[g], ga[g]) for g in gb.keys() & ga.keys())
    # najdłuższy rosnący podciąg po indeksie ASR
    tails, idx, prev = [], [], [-1]*len(pairs)
    for k, (_, j) in enumerate(pairs):
        p = bisect.bisect_left(tails, j)
        if p == len(tails): tails.append(j); idx.append(k)
        else: tails[p] = j; idx[p] = k
        prev[k] = idx[p-1] if p else -1
    res, k = [], idx[-1] if idx else -1
    while k >= 0: res.append(pairs[k]); k = prev[k]
    return res[::-1]

match = {}  # indeks w B -> indeks w A
def dp(bi0, bi1, ai0, ai1):
    nb, na = bi1-bi0, ai1-ai0
    if nb == 0 or na == 0: return
    if nb*na > 3_000_000: return
    GAP = -0.6
    S = [[0.0]*(na+1) for _ in range(nb+1)]; T = [[0]*(na+1) for _ in range(nb+1)]
    for i in range(1, nb+1): S[i][0] = i*GAP; T[i][0] = 1
    for j in range(1, na+1): S[0][j] = j*GAP; T[0][j] = 2
    for i in range(1, nb+1):
        bw = B[bi0+i-1]; Si, Sp = S[i], S[i-1]; Ti = T[i]
        for j in range(1, na+1):
            s = sim(bw, A[ai0+j-1]); m = Sp[j-1] + (2*s - 1)
            u, l = Sp[j] + GAP, Si[j-1] + GAP
            if m >= u and m >= l: Si[j] = m; Ti[j] = 0
            elif u >= l: Si[j] = u; Ti[j] = 1
            else: Si[j] = l; Ti[j] = 2
    i, j = nb, na
    while i > 0 and j > 0:
        t = T[i][j]
        if t == 0:
            if sim(B[bi0+i-1], A[ai0+j-1]) >= 0.6: match[bi0+i-1] = ai0+j-1
            i -= 1; j -= 1
        elif t == 1: i -= 1
        else: j -= 1

def solve(bi0, bi1, ai0, ai1, n):
    if (bi1-bi0)*(ai1-ai0) <= 40_000 or n < 2:
        dp(bi0, bi1, ai0, ai1); return
    anc = anchors(bi0, bi1, ai0, ai1, n)
    pb, pa = bi0, ai0
    for b, a in anc:
        if b < pb or a < pa: continue
        solve(pb, b, pa, a, n-1)
        for k in range(n): match[b+k] = a+k
        pb, pa = b+n, a+n
    solve(pb, bi1, pa, ai1, n-1)

solve(0, len(B), 0, len(A), 5)
print(f'matched book words {len(match)/len(B):.1%}, asr words {len(match)/len(A):.1%}')

# --- czasy zdań
per = defaultdict(list)
for b, a in match.items(): per[Bs[b]].append(a)
res = []
for si, s in enumerate(sentences):
    nw = sum(1 for w in s['text'].split() if norm(w))
    ms = per.get(si, [])
    r = {'i': si, 'spine': s['spine'], 'para': s['para'], 'text': s['text'], 'words': nw, 'matched': len(ms)}
    if ms and len(ms) >= max(1, nw*0.3):
        r['start'], r['end'] = At[min(ms)][0], At[max(ms)][1]
    res.append(r)
# interpolacja luk między zdaniami z czasem
timed = [k for k, r in enumerate(res) if 'start' in r]
RATE = sum(len(res[k]['text']) for k in timed) / sum(res[k]['end']-res[k]['start'] for k in timed)  # znaki na sekundę lektora
print(f'narrator rate {RATE:.1f} chars/s')
for x, y in zip(timed, timed[1:]):
    gap = range(x+1, y)
    if not gap: continue
    t0, t1 = res[x]['end'], res[y]['start']
    chars = sum(len(res[k]['text']) for k in gap)
    exp = chars / RATE  # oczekiwany czas czytania tej luki
    if t1 <= t0 or chars == 0 or not (0.4*exp <= t1-t0 <= 2.5*exp + 2): continue  # lektor pominął albo luka podejrzana
    acc = 0
    for k in gap:
        res[k]['start'] = t0 + (t1-t0)*acc/chars; acc += len(res[k]['text'])
        res[k]['end'] = t0 + (t1-t0)*acc/chars; res[k]['interp'] = True
direct = sum(1 for r in res if 'start' in r and not r.get('interp'))
interp = sum(1 for r in res if r.get('interp'))
words_timed = sum(r['words'] for r in res if 'start' in r)
print(f'sentences {len(res)}: direct {direct/len(res):.1%}, interpolated {interp/len(res):.1%}, '
      f'no time {(len(res)-direct-interp)/len(res):.1%}; words with time {words_timed/len(B):.1%}')
# zdania bez czasu (grupami)
runs, cur = [], []
for r in res:
    if 'start' not in r: cur.append(r)
    elif cur: runs.append(cur); cur = []
if cur: runs.append(cur)
runs.sort(key=lambda g: -sum(r['words'] for r in g))
print('largest untimed runs:')
for g in runs[:8]:
    print(f"  sent {g[0]['i']}-{g[-1]['i']} ({sum(r['words'] for r in g)} words): {g[0]['text'][:70]!r}")
# monotoniczność
bad = sum(1 for x, y in zip(timed, timed[1:]) if res[y]['start'] < res[x]['start'] - 0.5)
print('non-monotonic timed neighbours:', bad)
json.dump(res, open(out_path, 'w'), ensure_ascii=False)
