#!/usr/bin/env python3
"""Actual timer expiry, WKWebView, bundled sound and controls in isolated state."""
from pathlib import Path
import json,os,sqlite3,subprocess,time,uuid,wave,struct,math
B=Path(__file__).resolve().parents[1];APP=B/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=B/'.local'/('wellness-'+uuid.uuid4().hex);OUT=B/'build/verification/wellness'
(ROOT/'home').mkdir(parents=True);OUT.mkdir(parents=True,exist_ok=True)
for name in ['settings.png','current-view.json']:(OUT/name).unlink(missing_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(OUT),STARBUD_TEST_ISOLATE_MOUSE='1');results=[];previews=[]
def call(*args,payload=None):
 r=subprocess.run([str(CLI),*args],input=json.dumps(payload) if payload else None,text=True,capture_output=True,env=env,timeout=8)
 if r.returncode:raise RuntimeError(r.stderr)
 return json.loads(r.stdout)
def wait(fn,timeout=18):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  try:
   value=fn()
   if value:return value
  except (RuntimeError,ValueError,FileNotFoundError):pass
  time.sleep(.1)
 raise AssertionError('Reminder verification timed out')
def facts():
 with sqlite3.connect(ROOT/'state/state.sqlite') as db:return json.loads(db.execute('select data from snapshot').fetchone()[0])
def rows():
 data=[]
 for f in (ROOT/'state/logs').glob('*.jsonl'):
  for line in f.read_text().splitlines():
   try:data.append(json.loads(line))
   except ValueError:pass
 return data
def feedback():return [r for r in rows() if r['event']=='reminder_feedback']
def capture(*args):
 start=time.time();r=call('verify',*args)
 def read():
  d=json.loads((OUT/'current-view.json').read_text())
  return d if d['captureID']==r['captureID'] and (OUT/'pet-current.png').stat().st_mtime>=start else None
 return wait(read)
def check(ok,name):
 assert ok,name
 results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def dismiss():capture('--pet-ui','ackReminder')
p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(OUT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
 wait(lambda:call('status')['ok']);wait(lambda:(OUT/'settings.png').exists())
 call('verify','--toggle','walk');call('verify','--toggle','whispers')
 for kind,title,animation in [('focus','专注完成','点击回应-开心跃动'),('rest','休息一下','超大伸懒腰'),('water','喝口水吧','鲸鱼吐泡泡特效')]:
  before=facts()['reminders'];n=len(feedback());call('preview-reminder','--kind',kind);d=capture();u=d['ui']
  check(u['kind']=='wellness' and u['reminderTitle']==title and u['ackVisible'],kind+' shows the dedicated speech card and acknowledge action')
  check(u['background']=='rgba(255, 255, 255, 0.75)' and u['borderRadius']=='13px' and abs(u['width']-220)<.1,kind+' keeps compact size, 75% background and all rounded corners')
  check(u['summaryFitsOneLine'],kind+' friendly wording fits one complete line')
  check(u['withinViewport'] and abs(u['centerX']-u['headCenterX'])<1,kind+' card stays above and centered on the pet')
  check(u['laterVisible']==(kind!='focus'),kind+' shows snooze only for rest and water')
  check(d['pet']['action']==animation and d['pet']['ready'] and not d['pet']['error'],kind+' plays its own actual bundled animation')
  frames=OUT/'frames'/kind;frames.mkdir(parents=True,exist_ok=True)
  for frame in range(10):
   d=capture('--fast');(frames/(str(frame).zfill(2)+'.png')).write_bytes((OUT/'pet-current.png').read_bytes());time.sleep(.1)
  d=capture();(OUT/(kind+'.png')).write_bytes((OUT/'pet-current.png').read_bytes());previews.append({'kind':kind,'capture':d})
  check(len(feedback())==n+1 and feedback()[-1]['fields']['soundPlayed'],kind+' starts the soft sound once, not on periodic renders')
  dismiss();check(facts()['reminders']==before,kind+' preview and acknowledge preserve all timers')
  with wave.open(str(B/'Resources/sounds'/(kind+'.wav')),'rb') as w:
   dur=w.getnframes()/w.getframerate();samples=struct.unpack('<'+'h'*w.getnframes(),w.readframes(w.getnframes()));peak=max(abs(x) for x in samples)/32768
   check(1.9<dur<2.1 and peak<.3 and abs(samples[0])<2 and abs(samples[-1])<2,kind+' chime has short duration, restrained amplitude and smooth silent endpoints')
 # Preview snooze must never change the real reminder clocks.
 call('preview-reminder','--kind','water');capture();before=facts()['reminders'];capture('--pet-ui','laterReminder')
 check(facts()['reminders']==before,'snoozing a preview does not alter the real water timer')
 call('verify','--toggle','reminderSound');wait(lambda:facts()['settings'].get('reminderSound') is False)
 call('preview-reminder','--kind','rest');capture();check(not feedback()[-1]['fields']['soundPlayed'],'sound switch silences reminders while retaining the card');dismiss()
 call('verify','--toggle','reminderSound');call('verify','--toggle','reducedMotion');wait(lambda:facts()['settings']['reducedMotion'])
 call('preview-reminder','--kind','water');d=capture();check(d['ui']['kind']=='wellness' and d['pet']['paused'] and not feedback()[-1]['fields']['animationRequested'],'reduced motion freezes animation while keeping reminder visible');dismiss();call('verify','--toggle','reducedMotion')
 capture('--pet-ui','quiet');wait(lambda:facts()['settings']['quietUntil']>time.time());n=len(feedback());call('preview-reminder','--kind','rest');d=capture()
 check(d['ui']['noticeHidden'] and len(feedback())==n,'do not disturb produces neither reminder popup nor sound')
 capture('--pet-ui','quiet');wait(lambda:facts()['settings']['quietUntil']==0);capture();check(len(feedback())==n+1,'pending reminder presents once when do not disturb ends');dismiss()
 # Inject remaining time only, then use the production tick/clock/presentation pipeline.
 for kind in ['rest','water','focus','focusBreak']:
  n=len(feedback());d=capture('--fire-reminder',kind)
  check(d['ui']['kind']=='wellness' and not d['ui']['bubbleID'].startswith('preview-reminder:'),kind+' expiry reaches the real reminder pipeline')
  check(len(feedback())==n+1,kind+' actual expiry produces one feedback event')
  if kind=='water':
   capture('--pet-ui','laterReminder');check(590<facts()['reminders']['waterSnooze']<=600,'real water reminder snoozes for ten minutes')
  else:
   dismiss()
   if kind=='rest':check(facts()['reminders']['rest']<3,'rest acknowledge resets only its own elapsed time')
 # Higher priority Agent attention stays intact; wellness doesn't replace its animation.
 call('event',payload={'eventId':uuid.uuid4().hex,'agent':'codex','sessionId':'isolated-priority','turnId':'t','type':'attention.requested','requestId':'q'})
 capture();n=len(feedback());call('preview-reminder','--kind','water');d=capture()
 check(d['ui']['kind']=='agent' and len(feedback())==n,'Agent waiting remains visible and wellness sound waits its turn')
 check(not any(r['level']=='error' for r in rows()),'no native, webpage or video errors during reminder verification')
finally:
 try:call('quit')
 except Exception:p.terminate()
 p.wait(timeout=8)
 (OUT/'results.json').write_text(json.dumps({'results':results,'previews':previews,'dataRoot':str(ROOT),'boundary':'Isolated timer expiry and actual WKWebView/NSSound playback start; listening preference and physical speaker output require user judgment.'},ensure_ascii=False,indent=2)+'\n')
print('Checks:',len(results))
