#!/usr/bin/env python3
"""Offline source-integrity and Lean axiom audit. No native_decide or admitted proofs."""
import argparse, hashlib, json, pathlib, re, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
MODULES=['FastLeanIO.HTTPProofs','FastLeanIO.AppProofs','FastLeanIO.FormCodecProofs','FastLeanIO.Standards.Proofs']
ALLOWED={'propext','Classical.choice','Quot.sound'}
def main():
 p=argparse.ArgumentParser();p.add_argument('--output',default='results/standards-audit');args=p.parse_args();out=ROOT/args.output;out.mkdir(parents=True,exist_ok=True)
 manifest=json.loads((ROOT/'standards/manifest.json').read_text())
 for entry in manifest['sources']:
  path=ROOT/'standards'/entry['file'];assert hashlib.sha256(path.read_bytes()).hexdigest()==entry['sha256'],path
 expected=[]
 for module in MODULES:
  source=(ROOT/(module.replace('.','/')+'.lean')).read_text()
  assert not re.search(r'\b(?:sorry|admit|native_decide)\b',source),module
  expected+=re.findall(r'^theorem ([\w.]+)',source,re.M)
 with tempfile.NamedTemporaryFile(mode='w',suffix='.lean',dir=ROOT,delete=False) as f:
  f.write('\n'.join('import '+m for m in MODULES)+'\n')
  # Imports alone do not replay #print commands, so use fully qualified names.
  namespaces=['FastLeanIO.HTTP','FastLeanIO.App','FastLeanIO.FormCodec','FastLeanIO.Standards']
  for module,namespace in zip(MODULES,namespaces):
   source=(ROOT/(module.replace('.','/')+'.lean')).read_text()
   for name in re.findall(r'^theorem ([\w.]+)',source,re.M):f.write(f'#print axioms {namespace}.{name}\n')
  name=f.name
 try:r=subprocess.run(['lake','env','lean',name],cwd=ROOT,capture_output=True,text=True)
 finally:pathlib.Path(name).unlink()
 log=r.stdout+r.stderr;(out/'axioms.txt').write_text(log)
 assert r.returncode==0,log
 found={}
 for name,axioms in re.findall(r"'([^']+)' depends on axioms:\s*\[([^]]*)\]",log,re.S):
  values={x.strip() for x in axioms.split(',') if x.strip()};assert values<=ALLOWED,(name,values);found[name]=sorted(values)
 for name in re.findall(r"'([^']+)' does not depend on any axioms",log):found[name]=[]
 assert len(found)==len(expected),(len(found),len(expected),log)
 report={'passed':True,'normative_sources':len(manifest['sources']),'checked_theorems':len(found),'allowed_axioms':sorted(ALLOWED),'theorems':found}
 (out/'audit.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='theorems'},indent=2))
if __name__=='__main__':main()
