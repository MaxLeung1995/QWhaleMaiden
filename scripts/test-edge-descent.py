#!/usr/bin/env python3
"""Isolated AppKit + WKWebView coverage for route, animation boundary and tap escape."""
from pathlib import Path
import json,os,subprocess,time,uuid,math
BASE=Path(__file__).resolve().parents[1];APP=BASE/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=BASE/'.local'/('edge-descent-'+uuid.uuid4().hex);REPORT=BASE/'build/verification/edge-descent'
(ROOT/'home').mkdir(parents=True);REPORT.mkdir(parents=True,exist_ok=True)
for n in ['settings.png','current-view.json']:(REPORT/n).unlink(missing_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(REPORT),STARBUD_TEST_ISOLATE_MOUSE='1')
checks=[]
def call(*args):
 p=subprocess.run([str(CLI),*args],env=env,capture_output=True,text=True,timeout=8)
 if p.returncode:raise RuntimeError(p.stderr)
 return json.loads(p.stdout)
def wait(fn,timeout=15):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   r=fn()
   if r:return r
  except (FileNotFoundError,ValueError,RuntimeError):pass
  time.sleep(.05)
 raise AssertionError('Timed out')
def ui(name):return call('verify','--pet-ui',name,'--fast')
def capture(name=None):
 r=ui(name) if name else call('verify','--fast')
 def read():
  d=json.loads((REPORT/'current-view.json').read_text());return d if d['captureID']==r['captureID'] else None
 return wait(read)
def check(ok,name):
 assert ok,name
 checks.append(name);print('PASS: '+name,flush=True)
p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(REPORT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
 wait(lambda:call('status')['ok']);wait(lambda:(REPORT/'settings.png').exists())
 for place in ['dockProbeLeft','dockProbeMiddle','dockProbeRight']:
  ui(place);time.sleep(.1);before=call('status')['bodyScreenRect'];center=before[0]+before[2]/2
  ui('edgeQuiet');wait(lambda:call('status')['motion']['edgeQuiet']);samples=[];deadline=time.monotonic()+8
  while time.monotonic()<deadline:
   d=call('status');r=d['bodyScreenRect'];samples.append(r)
   if d['motion']['phase']=='idle':break
   time.sleep(.03)
  else:raise AssertionError('Descent did not finish')
  check(len({round(r[1],1) for r in samples})>=3,place+' visibly descends instead of teleporting')
  check(all(abs(r[0]+r[2]/2-center)<1.5 for r in samples),place+' holds the body horizontal position')
  check(all(b[1]<=a[1]+.5 for a,b in zip(samples,samples[1:])),place+' descends without bouncing upward')
  check(abs(d['geometry']['y']-d['geometry']['maxY'])<1,place+' lands on the corresponding screen bottom')
  pet=capture()['pet'];check(pet['mode']=='edgeQuiet' and pet['edgeSegment']=={'start':2.8,'end':7.6},place+' uses only the crouching interval')
  ui('edgeDragOut');wait(lambda:not call('status')['motion']['edgeQuiet'])
 call('verify','--toggle','reducedMotion');ui('dockProbeMiddle');ui('edgeQuiet')
 wait(lambda:call('status')['motion']['edgeQuiet']);wait(lambda:call('status')['motion']['phase']=='idle')
 d=call('status');check(abs(d['geometry']['y']-d['geometry']['maxY'])<1,'reduced motion still completes the bottom-edge placement')
 ui('edgeDragOut');wait(lambda:not call('status')['motion']['edgeQuiet'])
 logs=[json.loads(row) for f in (ROOT/'state/logs').glob('*.jsonl') for row in f.read_text().splitlines()]
 check(not [r for r in logs if r['level']=='error'],'descent and crouching produce no native or video errors')
 (REPORT/'results.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2));print(str(len(checks))+' descent checks passed')
finally:
 try:call('quit')
 except Exception:p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill();p.wait()
