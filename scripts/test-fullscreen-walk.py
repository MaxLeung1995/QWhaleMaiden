#!/usr/bin/env python3
"""Isolated AppKit + WKWebView coverage for route, animation boundary and tap escape."""
from pathlib import Path
import json,os,subprocess,time,uuid,math
BASE=Path(__file__).resolve().parents[1];APP=BASE/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=BASE/'.local'/('fullscreen-walk-'+uuid.uuid4().hex);REPORT=BASE/'build/verification/fullscreen-walk'
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
 check(110<=call('status')['motion']['nextWalkIn']<=300,'initial automatic walk timer is 120-300 seconds')
 ui('idleFresh');time.sleep(.4);before=capture();check(before['pet']['mode']=='idle' and before['pet']['ready'],'standing animation is playing')
 queued=capture('autoWalkDue');time.sleep(.2)
 check(call('status')['motion']['phase']=='idle' and queued['ui']['queuedWalk'],'automatic walk waits without interrupting standing animation')
 ui('finishIdle');wait(lambda:call('status')['motion']['phase']=='walk')
 wait(lambda:call('status')['motion']['walkVisualReady'])
 moving=capture();status=call('status')['motion']
 check(abs(status['vx'])>1 and abs(status['vy'])>1,'native walker moves diagonally across the desktop')
 check(moving['pet']['mode']=='walk' and moving['pet']['action'] in ['原地左转奔跑','螃蟹走路'],'walker uses existing side-on running animations')
 direction=1 if status['vx']>0 else -1
 check(moving['pet']['clipMirror']==-direction,'running portrait faces the actual horizontal direction')
 check(not moving['ui']['barVisible'],'movement does not expose toolbar')
 wait(lambda:call('status')['motion']['phase']=='idle')
 check(110<=call('status')['motion']['nextWalkIn']<=300,'automatic interval resets after departure')
 for _ in range(3):ui('petTap');time.sleep(.12)
 wait(lambda:call('status')['motion']['phase']=='walk');wait(lambda:call('status')['motion']['walkVisualReady'])
 fleeing=capture();v=call('status')['motion']
 check(fleeing['ui']['fleeing'] and 119<math.hypot(v['vx'],v['vy'])<121,'three taps trigger faster escape')
 check(not fleeing['ui']['barVisible'],'triple click does not open toolbar')
 wait(lambda:call('status')['motion']['phase']=='idle')
 for clip in ['原地左转奔跑','螃蟹走路']:
  for edge,direction in [('walkLeftEdge',1),('walkRightEdge',-1)]:
   call('verify','--walk-clip',clip,'--pet-ui',edge,'--fast')
   wait(lambda:call('status')['motion']['walkVisualReady'])
   d=capture();v=call('status')['motion']
   check(v['vx']*direction>0 and abs(v['vy'])>1,clip+' chooses inward diagonal at '+edge)
   check(d['pet']['action']==clip and d['pet']['clipMirror']==-direction and d['pet']['runSegment'] is not None,clip+' plays cropped running cycle facing movement')
   wait(lambda:call('status')['motion']['phase']=='idle')
 ui('queueWalk');capture('idleFresh');ui('autoWalkDue');ui('petTap')
 check(not capture()['ui']['queuedWalk'],'touch cancels an automatic walk waiting for animation end')
 ui('petTap');ui('petTap');wait(lambda:call('status')['motion']['phase']=='walk')
 call('verify','--toggle','reducedMotion');wait(lambda:call('status')['motion']['phase']=='idle')
 for _ in range(3):ui('petTap')
 check(call('status')['motion']['phase']=='idle','reduced motion blocks triple-tap escape')
 logs=[json.loads(row) for f in (ROOT/'state/logs').glob('*.jsonl') for row in f.read_text().splitlines()]
 check(not [r for r in logs if r['level']=='error'],'no native, JS or video errors in isolated run')
 (REPORT/'results.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
 print(str(len(checks))+' fullscreen walk checks passed')
finally:
 try:call('quit')
 except Exception:p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill();p.wait()
