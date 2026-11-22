import sys, zipfile, re, json, posixpath
from html.parser import HTMLParser
import xml.etree.ElementTree as ET

path = sys.argv[1]
z = zipfile.ZipFile(path)
cont = ET.fromstring(z.read('META-INF/container.xml'))
opf_path = cont.find('.//{*}rootfile').get('full-path')
opf = ET.fromstring(z.read(opf_path))
base = posixpath.dirname(opf_path)
man = {i.get('id'): i.get('href') for i in opf.find('{*}manifest')}
spine = [man[i.get('idref')] for i in opf.find('{*}spine')]

BLOCK = {'p','div','h1','h2','h3','h4','h5','h6','li','blockquote','br','tr'}
class P(HTMLParser):
    def __init__(s): super().__init__(); s.paras=[]; s.cur=[]; s.skip=0
    def handle_starttag(s,t,a):
        if t in ('script','style'): s.skip+=1
        if t in BLOCK: s.flush()
    def handle_endtag(s,t):
        if t in ('script','style'): s.skip-=1
        if t in BLOCK: s.flush()
    def handle_data(s,d):
        if not s.skip: s.cur.append(d)
    def flush(s):
        t=re.sub(r'\s+',' ',''.join(s.cur)).strip(); s.cur=[]
        if t: s.paras.append(t)

SENT = re.compile(r'(?<=[.!?…»”"])\s+(?=[„«"\-–—A-ZĄĆĘŁŃÓŚŹŻ0-9])')
out=[]
for si,href in enumerate(spine):
    p=P(); p.feed(z.read(posixpath.join(base,href)).decode('utf-8','replace')); p.flush()
    for pi,para in enumerate(p.paras):
        for s in SENT.split(para):
            if s.strip(): out.append({'spine':si,'href':href,'para':pi,'text':s.strip()})
json.dump(out, open(sys.argv[2],'w'), ensure_ascii=False)
print(len(out),'sentences', sum(len(s['text'].split()) for s in out),'words')
