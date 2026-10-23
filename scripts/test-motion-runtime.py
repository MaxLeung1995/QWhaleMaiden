#!/usr/bin/env python3
"""Real native timer/Window integration, isolated from user state and Agent logs."""
from pathlib import Path
import json, os, subprocess, time, uuid
BASE=Path(__file__).resolve().parents[1];APP=BASE/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=BASE/'.local'/('motion-'+uuid.uuid4().hex);REPORT=BASE/'build/verification/motion-runtime'
(ROOT/'home').mkdir(parents=True);REPORT.mkdir(parents=True,exist_ok=True)
for name in ['settings.png','current-view.json']:(REPORT/name).unlink(missing_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(REPORT),STARBUD_TEST_ISOLATE_MOUSE='1')
results=[]
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
def capture(action=None):
 r=call('verify',*(['--pet-ui',action] if action else []))
 def read():
  data=json.loads((REPORT/'current-view.json').read_text());return data if data['captureID']==r['captureID'] else None
 return wait(read)
def check(ok,name):
 assert ok,name
 results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def rows():
 return [json.loads(s) for p in sorted((ROOT/'state/logs').glob('*.jsonl')) for s in p.read_text().splitlines()]
p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(REPORT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
 wait(lambda:call('status')['ok']);wait(lambda:(REPORT/'settings.png').exists())
 call('verify','--toggle','walk');call('verify','--toggle','whispers')
 start=call('status');check(start['version']=='0.1.2','native motion build starts with diagnostic log path')
 for action in ['throwVertical','throwDiagonal','throwLeft']:
  began=capture(action);state=call('status')
  check(state['motion']['phase']=='flight',action+' continues past its initial upward phase')
  if action=='throwVertical':(REPORT/'vertical-airborne.png').write_bytes((REPORT/'pet-current.png').read_bytes())
  wait(lambda:call('status')['motion']['phase']=='idle',timeout=18)
  final=call('status');check(abs(final['motion']['y']+final['geometry']['maxY'])<.1,action+' finishes on body floor rather than mid screen')
  check(not final['through'],action+' does not enable pass-through')
 top=capture('topEdge');ceiling=call('status')
 check(abs(ceiling['motion']['y']+ceiling['geometry']['minY'])<1,'transparent window reaches body top bound instead of AppKit canvas top')
 latestBounds=[r for r in rows() if r['event']=='motion_bounds'][-1]['fields'];body=ceiling['bodyScreenRect'];screen=latestBounds['screen']
 check(abs(body[1]+body[3]-screen[1]-screen[3])<1,'actual pet head reaches top of available screen')
 (REPORT/'top-edge.png').write_bytes((REPORT/'pet-current.png').read_bytes())
 left=capture('leftEdge');leftState=call('status')
 check(left['ui']['menusOnRight'] and abs(leftState['motion']['x']-screen[0]+1)<1,'menu side switch changes no window-origin compensation')
 for animation in ['被鼠标拖拽悬空反馈','大口吃零食','打瞌睡被惊醒']:
  request=call('verify','--action',animation)
  wait(lambda:json.loads((REPORT/'current-view.json').read_text()).get('captureID')==request['captureID'])
  frame=json.loads((REPORT/'current-view.json').read_text())['pet']
  check(frame['visibleVideoCount']==1 and frame['videoTransition']=='0s','single visible video without crossfade: '+animation)
 capture('bottomEdge');capture('more');capture('tools');floor=capture()
 view=call('status')['overlayViewport'];card,first,second=floor['ui']['toolsLayout']
 check(floor['ui']['moreOpen'] and floor['ui']['gaps']['bottomAlignment']<.1,'bottom-edge More and toolbar still align')
 check(not floor['ui']['overlap']['more'] and not floor['ui']['overlap']['bar'],'bottom-edge controls avoid pet body')
 check(first['y']>=view['top'] and first['y']+first['height']<=view['bottom'],'bottom-edge tool buttons remain on desktop')
 (REPORT/'floor-tools.png').write_bytes((REPORT/'pet-current.png').read_bytes())
 time.sleep(1)
 logs=rows();edges={r['fields'].get('edge') for r in logs if r['event']=='motion_collision'}
 check({'left','right','bottom'}<=edges,'real native timer records side and floor collisions')
 settled=[r for r in logs if r['event']=='motion_settled'];check(len(settled)>=3,'every launched throw records a settled event')
 bounds=[r for r in logs if r['event']=='motion_bounds'];check(any(r['fields']['bounds'][0]<r['fields']['screen'][0] and r['fields']['bounds'][2]<r['fields']['screen'][1] for r in bounds),'native body bounds extend beyond transparent window origin')
 errors=[r for r in logs if r['level']=='error'];check(not errors,'no native motion or WebView errors during integration')
 check(not any(r['event']=='window_position_constrained' for r in logs),'no unexpected AppKit position clamping')
 samples=[r['fields'] for r in logs if r['event']=='motion_sample']
 (REPORT/'telemetry.json').write_text(json.dumps({'samples':samples,'errors':errors,'collisionEdges':sorted(edges),'logDirectory':str(ROOT/'state/logs')},ensure_ascii=False,indent=2)+'\n')
finally:
 try:call('quit')
 except Exception:p.terminate()
 p.wait(timeout=8)
 (REPORT/'results.json').write_text(json.dumps({'results':results,'dataRoot':str(ROOT),'boundary':'Native timer with injected throw velocities; not physical pointer smoothness acceptance.'},ensure_ascii=False,indent=2)+'\n')
print(str(REPORT/'results.json'))
