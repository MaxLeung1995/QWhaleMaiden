#!/usr/bin/env python3
"""Native movement and WKWebView capture; asset facing also needs visual review."""
from pathlib import Path
import json, os, subprocess, time, uuid
BASE=Path(__file__).resolve().parents[1];APP=BASE/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=BASE/'.local'/('walk-direction-'+uuid.uuid4().hex);REPORT=BASE/'build/verification/walk-direction'
(ROOT/'home').mkdir(parents=True);REPORT.mkdir(parents=True,exist_ok=True)
for name in ['settings.png','current-view.json']:(REPORT/name).unlink(missing_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(REPORT),STARBUD_TEST_ISOLATE_MOUSE='1')
results=[];samples=[]
def call(*args):
 p=subprocess.run([str(CLI),*args],env=env,capture_output=True,text=True,timeout=8)
 if p.returncode:raise RuntimeError(p.stderr)
 return json.loads(p.stdout)
def wait(fn,timeout=20):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   value=fn()
   if value:return value
  except (RuntimeError,ValueError,FileNotFoundError):pass
  time.sleep(.1)
 raise AssertionError('Native motion/capture timed out')
def capture(action=None,clip=None,fast=False):
 args=(['--pet-ui',action] if action else [])+(['--walk-clip',clip] if clip else [])+(['--fast'] if fast else [])
 r=call('verify',*args)
 def read():
  data=json.loads((REPORT/'current-view.json').read_text());return data if data['captureID']==r['captureID'] else None
 return wait(read)
def check(ok,name):
 assert ok,name
 results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def sample(label,data,clip,expected):
 pet=data['pet'];status=call('status');direction=1 if status['motion']['vx']>0 else -1
 check(status['motion']['phase']=='walk' and direction==expected,label+' travels in the expected direction')
 check(pet['mode']=='walk' and pet['action']==clip and pet['ready'] and not pet['error'],label+' uses selected running clip')
 mirror=-expected # Both originals visually verified facing left, not inferred from file names.
 check(pet['baseFacing']==-1 and pet['clipMirror']==mirror and pet['clipTransform'].startswith('matrix('+str(mirror)+','),label+' mirrors verified left-facing source correctly')
 segment=pet['runSegment'];check(segment and segment['start']-.05<=pet['time']<segment['end']+.05,label+' stays inside side-on running frames')
 check(pet['visibleVideoCount']==1 and pet['videoTransition']=='0s',label+' keeps one visible video')
 (REPORT/(label+'.png')).write_bytes((REPORT/'pet-current.png').read_bytes());samples.append({'label':label,'pet':pet,'motion':status['motion']})
def rows():
 return [json.loads(s) for p in sorted((ROOT/'state/logs').glob('*.jsonl')) for s in p.read_text().splitlines()]
p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(REPORT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
 wait(lambda:call('status')['ok']);wait(lambda:(REPORT/'settings.png').exists())
 call('verify','--toggle','whispers')
 for clip in ['原地左转奔跑','螃蟹走路']:
  for action,direction in [('walkLeftEdge',1),('walkRightEdge',-1)]:
   label=clip+'-'+action;data=capture(action,clip);first=call('status')['motion']['x'];started=time.monotonic();sample(label+'-early',data,clip,direction)
   time.sleep(.8);sample(label+'-middle',capture(fast=True),clip,direction)
   time.sleep(.7);sample(label+'-late',capture(fast=True),clip,direction)
   wait(lambda:call('status')['motion']['phase']=='idle',timeout=7)
   travelled=(call('status')['motion']['x']-first)*direction;elapsed=time.monotonic()-started
   check(75<=travelled<=125,label+' preserves subpixel movement at approximately 45 points per second')
 for action,direction in [('walkTurnLeft',-1),('walkTurnRight',1)]:
  call('verify','--pet-ui',action,'--walk-clip','螃蟹走路','--fast');time.sleep(.25)
  sample(action+'-before',capture(fast=True),'螃蟹走路',direction)
  wait(lambda:call('status')['motion']['vx']*direction<0,timeout=2);sample(action+'-after',capture(fast=True),'螃蟹走路',-direction)
  wait(lambda:call('status')['motion']['phase']=='idle',timeout=7)
 for action,mirror in [('runClipLeftEdge',-1),('runClipRightEdge',1)]:
  capture(action);time.sleep(1.4);pet=capture(fast=True)['pet']
  check(pet['mode']=='preview' and pet['action']=='原地左转奔跑' and pet['clipMirror']==mirror,action+' preserves original idle clip and inward facing')
 logs=rows()
 check(sum(r['event']=='walk_turn' for r in logs)>=2,'both native turnarounds update rendered direction')
 check(not any(r['level']=='error' for r in logs),'no native, webpage, or video errors')
finally:
 try:call('quit')
 except Exception:p.terminate()
 p.wait(timeout=8)
 (REPORT/'results.json').write_text(json.dumps({'results':results,'samples':samples,'dataRoot':str(ROOT),'boundary':'Native movement, verified source-facing transform, run-segment timing and WKWebView captures; images require visual review'},ensure_ascii=False,indent=2)+'\n')
