#!/usr/bin/env python3
"""Check actual notification action bounds and symmetric outer insets."""
from pathlib import Path
import json,os,subprocess,time,uuid
B=Path(__file__).resolve().parents[1];APP=B/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event';ROOT=B/'.local'/('agent-actions-'+uuid.uuid4().hex);OUT=B/'build/verification/agent-actions'
(ROOT/'home').mkdir(parents=True);OUT.mkdir(parents=True,exist_ok=True)
for name in ['settings.png','current-view.json']:(OUT/name).unlink(missing_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(OUT),STARBUD_TEST_ISOLATE_MOUSE='1');results=[]
def call(*args,payload=None):
 r=subprocess.run([str(CLI),*args],input=json.dumps(payload) if payload else None,text=True,capture_output=True,env=env,timeout=8)
 if r.returncode:raise RuntimeError(r.stderr)
 return json.loads(r.stdout)
def wait(fn):
 end=time.monotonic()+18
 while time.monotonic()<end:
  try:
   value=fn()
   if value:return value
  except (RuntimeError,FileNotFoundError,ValueError):pass
  time.sleep(.1)
 raise AssertionError('Capture timed out')
def check(ok,name):
 assert ok,name
 results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def capture():
 r=call('verify')
 def read():
  data=json.loads((OUT/'current-view.json').read_text());return data if data['captureID']==r['captureID'] else None
 return wait(read)
p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(OUT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
 wait(lambda:call('status')['ok']);wait(lambda:(OUT/'settings.png').exists())
 for i in range(4):call('event',payload={'eventId':'align-'+str(i),'agent':'codex','sessionId':'align-'+str(i),'turnId':'t','type':'attention.requested','requestId':'q-'+str(i),'summary':'需要你回答'})
 data=capture();ui=data['ui'];top,bottom=ui['agentActionButtons']
 check(top['visible'] and bottom['visible'],'both close and later actions are visible')
 check(abs(top['width']-bottom['width'])<.1 and abs(top['height']-bottom['height'])<.1,'action buttons have identical width and height')
 check(abs(top['x']-bottom['x'])<.1 and abs(top['rightInset']-bottom['rightInset'])<.1,'left right edges and horizontal centers align')
 check(abs(top['topInset']-bottom['bottomInset'])<.1,'top and bottom outer margins are symmetric')
 check(ui['closeButtons'][1]['centerError']<.1,'close cross is centered in its action button')
 check(ui['background']=='rgba(255, 255, 255, 0.85)' and ui['borderRadius']=='18px' and ui['withinViewport'],'85 percent rounded notification remains fully visible')
 (OUT/'aligned.png').write_bytes((OUT/'pet-current.png').read_bytes())
 for i in range(4):call('event',payload={'eventId':uuid.uuid4().hex,'agent':'codex','sessionId':'align-'+str(i),'turnId':'t','type':'attention.resolved'})
 call('verify','--toggle','preview')
 samples=[]
 for agent in ['codex','workbuddy','trae','lingxi']:
  for summary in ['本轮回复结束','本轮执行失败','需要浏览器确认','需要你回答','状态较久未更新，请回到应用核实']:
   turn=uuid.uuid4().hex
   def event(kind):
    call('event',payload={'eventId':uuid.uuid4().hex,'agent':agent,'sessionId':'width-'+agent,'turnId':turn,'type':kind,'requestId':turn,'summary':summary})
   event('turn.started');event('attention.requested');sample=capture();u=sample['ui']
   check(sample['text']==summary and u['summaryFitsOneLine'],agent+' '+summary+' fits on one complete line')
   check(u['width']<=208 and (len(summary)>10 or abs(u['width']-136)<1),'compact width without oversized common-status card')
   samples.append({'agent':agent,'text':summary,'width':u['width']})
   event('attention.resolved')
 (OUT/'width-samples.json').write_text(json.dumps(samples,ensure_ascii=False,indent=2)+'\n')

 (OUT/'geometry.json').write_text(json.dumps(ui,ensure_ascii=False,indent=2)+'\n')
finally:
 try:call('quit')
 except Exception:p.terminate()
 p.wait(timeout=8)
 (OUT/'results.json').write_text(json.dumps({'results':results,'boundary':'Isolated real WKWebView notification using four fixture events'},ensure_ascii=False,indent=2)+'\n')
