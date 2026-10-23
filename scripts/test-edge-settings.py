#!/usr/bin/env python3
"""Isolated AppKit + WKWebView coverage for route, animation boundary and tap escape."""
from pathlib import Path
import json,os,subprocess,time,uuid,math
BASE=Path(__file__).resolve().parents[1];APP=BASE/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=BASE/'.local'/('edge-settings-'+uuid.uuid4().hex);REPORT=BASE/'build/verification/edge-settings'
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
 call('verify','--toggle','whispers')
 capture('bar');capture('more');d=capture('manage')
 check(d['ui']['manageButtons']==['换个形象','鼠标穿透','全部设置','退出桌宠'],'management contains only the four requested controls')
 rects=d['ui']['manageLayout']
 check(rects[0]['width']==rects[1]['width']==rects[2]['width']==rects[3]['width'] and rects[0]['y']==rects[1]['y'] and rects[2]['y']==rects[3]['y'],'management buttons form a symmetric two by two grid')
 check(d['ui']['manageFits'],'all management controls fit the fixed panel without scrolling')
 (REPORT/'manage.png').write_bytes((REPORT/'pet-current.png').read_bytes())
 ui('openPacks');time.sleep(.7)
 def settings():return json.loads((REPORT/'settings-view.json').read_text())
 capture();wait(lambda:settings()['tab']=='packs')
 check(settings()['title']=='换个形象','management change appearance opens its original settings page')
 for size,width in [('settingsLarge',860),('settingsSmall',700)]:
  ui(size)
  for tab,title in [('companion','陪伴与互动'),('agents','Agent 接入'),('life','专注与休息'),('widgets','天气与日历'),('packs','换个形象')]:
   call('verify','--tab',tab,'--fast');time.sleep(.15);capture()
   wait(lambda:settings()['tab']==tab and settings()['width']==width)
   q=settings()
   check(q['title']==title and q['sections']==[tab] and q['documentFits'],size+' '+tab+' has correct grouping with no page overflow')
   check(all(c['x']>=0 and c['x']+c['width']<=width+1 for c in q['controls']),size+' '+tab+' keeps controls inside window')
   time.sleep(.1);(REPORT/(size+'-'+tab+'.png')).write_bytes((REPORT/'panel-current.png').read_bytes())
 capture('edgeQuiet');time.sleep(.8);d=capture();status=call('status')
 check(status['motion']['edgeQuiet'] and d['pet']['mode']=='edgeQuiet','edge quiet activates native docking and hiding animation')
 check(status['bodyScreenRect'][3]<=33 and abs(status['geometry']['y']-status['geometry']['maxY'])<1,'head-only hit target sits exactly on bottom boundary')
 check(d['pet']['action']=='原地重力下蹲压缩' and d['pet']['edgeSegment'] is not None and not d['pet']['paused'],'hiding segment plays as an animation')
 check(d['ui']['noticeHidden'] and not d['ui']['barVisible'] and not d['ui']['moreOpen'],'docking closes menus and notification surfaces')
 samples=[]
 for _ in range(3):time.sleep(2);samples.append(capture()['pet'])
 check(all(x['mode']=='edgeQuiet' and 2.2<=x['time']<=7.8 for x in samples),'hiding segment continues looping without random actions')
 ui('autoWalkDue');check(call('status')['motion']['phase']=='idle','automatic wandering stays paused while docked')
 call('preview-reminder','--kind','water');check(capture()['ui']['noticeHidden'],'docked reminders do not pop up')
 for _ in range(3):ui('petTap');time.sleep(.12)
 wait(lambda:not call('status')['motion']['edgeQuiet'])
 check(call('status')['motion']['phase']=='walk','triple tap exits docking and runs away')
 wait(lambda:call('status')['motion']['phase']=='idle')
 capture('edgeQuiet');time.sleep(.7);capture('edgeDragOut')
 check(not call('status')['motion']['edgeQuiet'] and call('status')['bodyScreenRect'][3]>100,'dragging restores the full body and exits docking')
 call('verify','--tab','companion');time.sleep(.4);capture()
 # Use the same native through handler as the management button, then the existing escape gesture.
 ui('through');time.sleep(.6);check(call('status')['through'],'mouse pass-through still uses the existing native implementation')
 ui('escapeGesture');time.sleep(.2);check(not call('status')['through'],'existing three-finger escape restores mouse interaction')
 logs=[json.loads(row) for f in (ROOT/'state/logs').glob('*.jsonl') for row in f.read_text().splitlines()]
 check(not [r for r in logs if r['level']=='error'],'no native, webpage or video errors during docking and settings checks')
 (REPORT/'results.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
 print(str(len(checks))+' edge quiet/settings checks passed')
finally:
 try:call('quit')
 except Exception:p.terminate()
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:p.kill();p.wait()
