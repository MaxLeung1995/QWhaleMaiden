#!/usr/bin/env python3
"""Isolated native input guards, display geometry, hook integration and plugin lifecycle."""
from pathlib import Path
import json, os, shlex, sqlite3, subprocess, time, uuid

B=Path(__file__).resolve().parents[1];APP=B/'build/QWhaleMaiden.app';CLI=APP/'Contents/Helpers/starbud-event'
ROOT=B/'.local'/('phase2-'+uuid.uuid4().hex);OUT=B/'build/verification/phase2'
(ROOT/'home').mkdir(parents=True);OUT.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,STARBUD_DATA_DIR=str(ROOT/'state'),STARBUD_SOURCE_HOME=str(ROOT/'home'),STARBUD_SMOKE_DIR=str(OUT),STARBUD_TEST_ISOLATE_MOUSE='1')
results=[]
def call(*args,payload=None,expect=True):
    p=subprocess.run([str(CLI),*args],input=json.dumps(payload) if payload is not None else None,text=True,capture_output=True,env=env,timeout=8)
    if expect and p.returncode:raise RuntimeError(p.stderr)
    return json.loads(p.stdout) if expect else p
def check(ok,name):
    assert ok,name
    results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def wait(fn,timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        try:
            value=fn()
            if value:return value
        except (FileNotFoundError,ValueError,RuntimeError):pass
        time.sleep(.1)
    raise AssertionError('Timed out')
def capture(ui=None):
    r=call('verify',*(['--pet-ui',ui] if ui else []))
    return wait(lambda: (lambda d:d if d['captureID']==r['captureID'] else None)(json.loads((OUT/'current-view.json').read_text())))
def task(agent,session):
    c=sqlite3.connect((ROOT/'state/state.sqlite').as_uri()+'?mode=ro',uri=True)
    # Read only this test instance's own snapshot.
    raw=c.execute('select data from snapshot').fetchone()[0];c.close()
    return json.loads(raw)['tasks'].get(agent+':'+session)

# Plugin installation and exact removal in a disposable home.
home=ROOT/'home';patch=home/'.dsh/profiles/desktop/cordis.patch.yml';patch.parent.mkdir(parents=True)
original='# user configuration\n- id: user-plugin\n  config:\n    enabled: true\n';patch.write_text(original)
for agent,relative in [('dsh','.dsh/profiles/desktop/starbud-bridge'),('qwenwork','.qwenworkcn/plugins-custom/starbud-bridge')]:
    call('setup','--agent',agent,'--home',str(home));check(not (home/relative).exists(),agent+' dry-run performs no writes')
    call('setup','--agent',agent,'--home',str(home),'--apply');check((home/relative/'.starbud-owned').exists(),agent+' installs owned plugin')
    call('setup','--agent',agent,'--home',str(home),'--apply')
check(patch.read_text().count('id: starbud-bridge')==1 and original in patch.read_text(),'DSH repeat install preserves existing config without duplicate entries')
hooks=json.loads((home/'.qwenworkcn/plugins-custom/starbud-bridge/hooks.json').read_text())['hooks']
check('PermissionRequest' in hooks and 'StopFailure' not in hooks,'QwenWork permissions configured without treating hook failure as task failure')
for agent in ['dsh','qwenwork']:call('setup','--agent',agent,'--home',str(home),'--apply','--remove')
check(patch.read_text()==original,'DSH uninstall restores unrelated configuration exactly')

# Run the real DSH plugin against a stub host and an executable that records only its output.
helper=ROOT/'capture-hook';lines=ROOT/'plugin-events.jsonl'
helper.write_text('#!/bin/sh\ncat >> '+shlex.quote(str(lines))+'\nprintf "\\n" >> '+shlex.quote(str(lines))+'\n');helper.chmod(0o700)
driver=ROOT/'plugin-test.mjs'
driver.write_text('''import {apply} from '''+json.dumps((B/'Resources/bridges/dsh/index.mjs').as_uri())+''';
let handler,dispose;const ctx={on:(name,fn)=>{handler=fn;return()=>{}},effect:fn=>{dispose=fn()}};
apply(ctx,{helperPath:process.argv[2]});
const session={header:{id:'test-session'}};
handler(session,{type:'turn/start',seq:1,data:{private:'DO_NOT_FORWARD'}});
handler(session,{type:'turn/start',seq:1});
handler(session,{type:'approval/asked',seq:2,data:{id:'permission',reason:'DO_NOT_FORWARD'}});
handler(session,{type:'tool/result',seq:3,data:{id:'permission',result:'DO_NOT_FORWARD'}});
handler(session,{type:'turn/end',seq:4,data:{reason:{kind:'completed'}}});
handler({header:{id:'child',origin:'subagent'}},{type:'turn/start',seq:1});
await new Promise(r=>setTimeout(r,1000));dispose();
''')
subprocess.run(['node',str(driver),str(helper)],check=True,timeout=8)
events=[json.loads(s) for s in lines.read_text().splitlines()]
check(len(events)==4 and [e['sequence'] for e in events]==[1,2,3,4],'DSH plugin suppresses duplicate start and child sessions')
check('DO_NOT_FORWARD' not in lines.read_text(),'DSH bridge forwards no tool result, prompt or approval content')
check(events[2].get('resolves_wait') and events[2]['request_id']=='permission','DSH resolves only matching request identity')

p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(OUT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
    wait(lambda:call('status')['ok']);wait(lambda:(OUT/'settings.png').exists());time.sleep(1)
    call('verify','--toggle','walk');call('verify','--toggle','whispers')
    capture('throwVertical')
    check(call('status')['motion']['phase']=='flight','native throw is active for gesture regression')
    u=capture('menuProbe')['ui'];check(not u['barVisible'] and not u['moreOpen'],'hover, context menu and double click cannot open controls during bounce')
    wait(lambda:call('status')['motion']['phase']=='idle',timeout=18);time.sleep(.8)
    u=capture('bar')['ui'];check(u['barVisible'],'normal menu still opens after movement settles')
    capture('escape')
    q={'session_id':'qwen-test','hook_event_name':'UserPromptSubmit','event_id':'qw-start'}
    call('hook','--agent','qwenwork',payload=q)
    q.update(hook_event_name='PermissionRequest',tool_use_id='permission-q',event_id='qw-permission');call('hook','--agent','qwenwork',payload=q)
    check(task('qwenwork','qwen-test')['status']=='waiting','QwenWork permission hook reaches native waiting state')
    q.update(hook_event_name='Stop',event_id='qw-early-stop');call('hook','--agent','qwenwork',payload=q)
    check(task('qwenwork','qwen-test')['status']=='waiting','QwenWork Stop cannot erase unanswered permission')
    q.update(hook_event_name='PostToolUse',event_id='qw-resume');call('hook','--agent','qwenwork',payload=q)
    check(task('qwenwork','qwen-test')['status']=='active','QwenWork matching post-tool event resumes permission wait')
    for e in events:
        r=call('hook','--agent','dsh',payload=e)
    check(task('dsh','test-session')['status']=='ended','actual DSH plugin output traverses helper, socket and native reducer')
    check(not call('hook','--agent','dsh',payload=events[-1])['accepted'],'DSH duplicate completion does not replay')
    q.update(hook_event_name='Stop',event_id='qw-end');call('hook','--agent','qwenwork',payload=q)
    data=capture();check(data['ui']['borderRadius']=='18px' and data['ui']['background']=='rgba(255, 255, 255, 0.85)','new sources preserve existing rounded 85-percent agent style')
    logs=[json.loads(s) for f in (ROOT/'state/logs').glob('*.jsonl') for s in f.read_text().splitlines()]
    check(not [r for r in logs if r['level']=='error'],'no native or webpage errors in phase two integration')
finally:
    try:call('quit')
    except Exception:p.terminate()
    p.wait(timeout=8)
    (OUT/'results.json').write_text(json.dumps({'results':results,'dataRoot':str(ROOT),'boundary':'Isolated native app and stub DSH host; actual user-host dispatch and physical mouse/monitor unplug remain separate acceptance.'},ensure_ascii=False,indent=2))
