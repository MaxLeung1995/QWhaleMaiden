#!/usr/bin/env python3
"""Real app/CLI integration with isolated sources and data. Never writes production Agent settings."""
from pathlib import Path
import json, os, subprocess, time, uuid, sqlite3

BASE = Path(__file__).resolve().parents[1]
APP = BASE/'build/QWhaleMaiden.app'
CLI = APP/'Contents/Helpers/starbud-event'
ROOT = BASE/'.local'/('runtime-'+uuid.uuid4().hex)
REPORT = BASE/'build/verification/runtime'
ROOT.mkdir(parents=True); REPORT.mkdir(parents=True,exist_ok=True)
for filename in ['webview.json','settings.png','pet.png','current-view.json','pet-current.png','panel-current.png']:
    (REPORT/filename).unlink(missing_ok=True)
HOME = ROOT/'home'; HOME.mkdir()
env = dict(os.environ, STARBUD_DATA_DIR=str(ROOT/'state'), STARBUD_SOURCE_HOME=str(HOME), STARBUD_SMOKE_DIR=str(REPORT), STARBUD_TEST_ISOLATE_MOUSE="1")
results=[]
def call(command, *args, payload=None, check=True):
    run=subprocess.run([str(CLI),command,*args],input=None if payload is None else json.dumps(payload),text=True,capture_output=True,env=env,timeout=8)
    if check and run.returncode: raise RuntimeError(run.stderr)
    return json.loads(run.stdout) if run.stdout.strip() else {}
def wait(fn, timeout=22):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        try:
            value=fn()
            if value:return value
        except (RuntimeError,ValueError,FileNotFoundError,KeyError):pass
        time.sleep(.25)
    raise AssertionError('Timed out: '+fn.__name__)
def check(condition,name):
    assert condition,name
    results.append({'name':name,'status':'pass'});print('PASS: '+name,flush=True)
def facts():
    with sqlite3.connect(str(ROOT/'state/state.sqlite')) as db:
        row=db.execute('SELECT data FROM snapshot WHERE id=1').fetchone()
        return json.loads(row[0]) if row else {}
def capture_ui(action=None):
    target=REPORT/'current-view.json';old=target.stat().st_mtime_ns if target.exists() else 0
    response=call('verify',*(['--pet-ui',action] if action else []))
    wait(lambda:target.exists() and json.loads(target.read_text()).get('captureID')==response['captureID'])
    return json.loads(target.read_text())
def save_shot(name):
    time.sleep(.2);(REPORT/name).write_bytes((REPORT/'pet-current.png').read_bytes())
def append(path, rows):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('a') as f:
        for row in rows:f.write(json.dumps(row,ensure_ascii=False)+'\n')

process=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(REPORT/'app.log').open('w'),stderr=subprocess.STDOUT)
try:
    wait(lambda:call('status').get('ok'))
    wait(lambda:(REPORT/'webview.json').exists(),timeout=12)
    wait(lambda:(REPORT/'settings.png').exists(),timeout=12)
    initial=json.loads((REPORT/'webview.json').read_text())
    check(initial['error']=='','native WKWebView initializes')
    check(call('status')['statusIconVisible'] is False,'status bar icon stays hidden')
    check(facts()['reminders']['focusRemaining']==2700,'new app snapshot defaults to 45 minute focus')
    call('verify','--tab','life');time.sleep(.7)
    call('verify','--focus','start');wait(lambda:facts()['reminders']['focusMode']=='running')
    check(2690<facts()['reminders']['focusRemaining']<=2700,'settings start button starts 45 minute countdown')
    call('verify','--focus','cancel');wait(lambda:facts()['reminders']['focusMode']=='stopped')
    check(facts()['reminders']['focusRemaining']==2700,'cancel resets focus to 45 minutes')
    call('verify','--toggle','whispers');wait(lambda:not facts()['settings']['whispers'])
    compact=capture_ui('bar')['ui']
    check(compact['barWidth']==132 and compact['barHeight']==28 and compact['barActions']==['开始番茄钟','更多'],'smaller 132 by 28 foot bar has exactly two actions')
    capture_ui('focus');wait(lambda:facts()['reminders']['focusMode']=='running')
    check(capture_ui('bar')['ui']['barActions']==['关闭番茄钟','更多'],'foot bar starts focus and reflects active countdown')
    check(capture_ui('more')['ui']['moreOpen'],'More opens in a real WKWebView')
    check(capture_ui('tools')['ui']['moreTab']=='tools','More switches to tools page')
    fixed=capture_ui()['ui']
    check(fixed['moreSize']=={'width':244,'height':248} and not fixed['overlap']['more'] and not fixed['overlap']['bar'],'fixed side menu and bottom toolbar do not overlap pet body')
    check(abs(fixed['gaps']['bar']-6)<1 and 7<=fixed['gaps']['side']<=20 and abs(fixed['gaps']['toolbarSide']-8)<1 and fixed['gaps']['bottomAlignment']<1,'menu clears the body and aligns its bottom eight points beside toolbar six points below feet')
    save_shot('more-tools.png')
    check(fixed['closeButtons'][0]['width']==18 and fixed['closeButtons'][0]['height']==18 and fixed['closeButtons'][0]['centerError']<.1,'smaller More close button has a geometrically centered cross')
    check(call('status')['menuClickMonitoring'],'mouse-only local and global menu monitors are installed')
    capture_ui('insideClick')
    check(capture_ui()['ui']['moreOpen'],'native inside-menu click preserves the panel')
    before=facts()['reminders']['focusRemaining']
    capture_ui('widgetFixture')
    widgets=capture_ui('widgets')['ui']
    check(widgets['widgetsExpanded'] and not widgets['clockVisible'] and '上海' in widgets['weatherText'] and '23°C' in widgets['weatherText'],'weather expands inside focus card using configured data')
    check('今日测试日程' in widgets['todayCalendar'] and '明日测试日程' not in widgets['todayCalendar'],'inline calendar filters to today only')
    check(widgets['moreSize']==fixed['moreSize'] and widgets['toolsLayout']==fixed['toolsLayout'],'weather calendar expansion keeps card and both action buttons stationary')
    save_shot('inline-widgets.png')
    restored=capture_ui('widgets')['ui']
    check(restored['toolsLayout']==fixed['toolsLayout'],'returning to countdown preserves tools row coordinates')
    check(not restored['widgetsExpanded'] and restored['clockVisible'] and facts()['reminders']['focusMode']=='running','second widget click restores live focus countdown')
    check(restored['rightAction']=='专注与休息','right shortcut uses focus and rest label')
    capture_ui('focusSettings');time.sleep(.5)
    check(json.loads((REPORT/'settings-view.json').read_text())['tab']=='life','focus and rest keeps original settings destination')
    capture_ui('more');capture_ui('tools');capture_ui('outsideClick')
    check(not capture_ui()['ui']['barVisible'] and not capture_ui()['ui']['moreOpen'],'native click outside pet window dismisses both toolbar and More')
    check(not call('status')['menuClickMonitoring'],'outside menu click monitors detach when toolbar closes')
    capture_ui('clearWidgetFixture');capture_ui('more');capture_ui('tools')

    capture_ui('pause');wait(lambda:facts()['reminders']['focusMode']=='paused')
    check(True,'More pause button controls the real focus timer')
    capture_ui('bar');capture_ui('focus');wait(lambda:facts()['reminders']['focusMode']=='stopped')
    capture_ui('more')
    check(capture_ui('manage')['ui']['moreTab']=='manage','More switches to management page')
    check(capture_ui()['ui']['moreSize']==fixed['moreSize'],'management tab retains the same fixed menu size')
    save_shot('more-manage.png')
    capture_ui('through');wait(lambda:call('status')['through'])
    escape=call('status')['escape']
    check(escape['hotkeyRegistered'] and escape['enabled'],'pass-through has an independent registered recovery hotkey')
    (REPORT/'escape-availability.json').write_text(json.dumps(escape,indent=2)+'\n')
    capture_ui('escapeGesture');wait(lambda:not call('status')['through'])
    check(not call('status')['escape']['enabled'],'three three-finger contact sequences exit pass-through and remove recovery listeners')
    capture_ui('more');capture_ui('manage');capture_ui('through');wait(lambda:call('status')['through'])
    capture_ui('settingsRecover');wait(lambda:not call('status')['through'])
    check(True,'settings recovery button exits pass-through without clicking the pet')
    capture_ui('more');capture_ui('manage')
    check(not capture_ui('escape')['ui']['moreOpen'],'Escape closes More')
    capture_ui('leftEdge');side=capture_ui('more')['ui']
    check(side['menusOnRight'] and not side['overlap']['more'] and not side['overlap']['bar'],'menu docks on the opposite side at left screen edge without covering pet')
    capture_ui('rightEdge');side=capture_ui()['ui']
    check(not side['menusOnRight'] and not side['overlap']['more'],'menu docks back on the left at right screen edge')
    capture_ui('escape')
    texts=[]
    for _ in range(4):
        capture_ui('more');capture_ui('interact')
        save_shot('more-interact.png')
        spoken=capture_ui('whisper');texts.append(spoken['text'])
        call('verify','--scenario','clear')
    check(len(set(texts))==4 and all(texts),'manual chatter rotates four distinct local lines')
    capture_ui('idle')
    idle=capture_ui()['pet']
    check(idle['mode']=='idle' and idle['randomCount']==85,'idle stays awake after two minutes and exposes all 85 random actions')
    before=len(idle['history'])
    for _ in range(5):
        capture_ui('nextRandom');time.sleep(.3)
    cycle=capture_ui()['pet']
    check(len(cycle['history'])>=before+4 and cycle['randomCategory']!='','real video end transitions continue the weighted random animation chain')
    (REPORT/'companion.json').write_text(json.dumps({'manualChatter':texts,'randomPlayback':cycle,'bar':compact},ensure_ascii=False,indent=2)+'\n')
    call('verify','--scenario','whisper');time.sleep(1)
    speech=json.loads((REPORT/'current-view.json').read_text())['ui']
    check(speech['kind']=='whisper' and speech['withinViewport'] and speech['borderRadius']=='13px' and abs(speech['centerX']-speech['headCenterX'])<1 and 7<=speech['headGap']<=9,'whisper centers 8 points above pet head')
    check(speech['background']=='rgba(255, 255, 255, 0.75)','whisper background uses 75 percent opacity')
    check(speech['moreButton'],'hidden status icon retains pet context controls')
    (REPORT/'whisper.png').write_bytes((REPORT/'pet-current.png').read_bytes())
    call('verify','--scenario','clear')
    pet=json.loads(initial['view'])
    check(pet['renderer']=='dsh-hevc-alpha' and pet['ready'] and pet['time']>0 and not pet['error'],'bundled DSH animation actually decodes and plays')
    check(pet['alpha']['transparent']>150000 and pet['alpha']['visible']>10000,'decoded video preserves transparent background and visible character')
    check(abs(pet['body']['height']-132)<1,'pet body matches whale-girl 132 point reference')
    for action in ['被鼠标拖拽悬空反馈','大口吃零食','三球抛接','原地小憩沉眠','工作状态-忙碌点按','工作状态-雀跃庆祝']:
        call('verify','--action',action)
        wait(lambda:json.loads((REPORT/'current-view.json').read_text()).get('pet',{}).get('action')==action)
        sample=json.loads((REPORT/'current-view.json').read_text())['pet']
        check(sample['ready'] and sample['alpha']['transparent']>100000, 'transparent DSH action plays: '+action)
    call('verify','--toggle','reducedMotion')
    wait(lambda:facts()['settings']['reducedMotion'])
    time.sleep(1);call('verify');time.sleep(1)
    check(json.loads((REPORT/'current-view.json').read_text())['pet']['paused'],'reduced motion freezes bundled video')
    call('verify','--toggle','reducedMotion')
    wait(lambda:not facts()['settings']['reducedMotion'])
    call('verify','--action','待机呼吸休闲')
    wait(lambda:call('status').get('hitRegions',0)>0)
    check(True,'WebView reports native interactive hit regions')
    call('verify','--toggle','preview');wait(lambda:facts()['settings']['preview'])
    check(True,'settings DOM control crosses native bridge and persists')
    event={'eventId':'runtime-direct','agent':'codex','sessionId':'direct','turnId':'t','type':'attention.requested','requestId':'direct-q','summary':'test'}
    check(call('event',payload=event)['accepted'],'CLI event reaches real app')
    check(not call('event',payload=event)['accepted'],'CLI duplicate rejected by persistent ledger')
    original=capture_ui();capture_ui('more');capture_ui('interact')
    target=REPORT/'current-view.json';stamp=target.stat().st_mtime_ns;started=time.time()*1000
    fast=call('verify','--pet-ui','feed','--fast');wait(lambda:json.loads(target.read_text()).get('captureID')==fast['captureID'])
    instant=json.loads(target.read_text())
    check(instant['ui']['actionPending'] and not instant['ui']['barVisible'] and not instant['ui']['moreOpen'],'feeding closes all menus immediately before deferred action')
    done=capture_ui()
    check(done['ui']['lastMenuAction']=='eat' and done['ui']['lastMenuActionAt']-started>=480 and done['mode']=='eat','feeding executes after half second and plays with task notification still present')
    check(done['ui']['bubbleID']==original['ui']['bubbleID'] and done['source']==original['source'],'pet interaction preserves Agent notification identity')
    for agent in ['workbuddy','trae']:
        call('hook','--agent',agent,payload={'session_id':agent+'-fixture','hook_event_name':'PermissionRequest','request_id':'approval','prompt':'DO_NOT_PERSIST_THIS_PROMPT'})
    check(call('status')['bubbles']==3,'three sources coexist as independent bubbles')
    log=HOME/'.codex/sessions/test/rollout-fixture.jsonl'
    append(log,[{'type':'session_meta','payload':{'id':'runtime-codex'}},{'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-1'}},{'type':'response_item','payload':{'type':'function_call','name':'functions.request_user_input_async','call_id':'ask-async'}}])
    wait(lambda:facts()['tasks'].get('codex:runtime-codex',{}).get('status')=='waiting')
    check(True,'real process consumes appended Codex JSONL')
    append(log,[{'type':'response_item','payload':{'type':'function_call_output','call_id':'ask-async','output':'{"accepted":true}'}},{'type':'event_msg','payload':{'type':'task_complete'}}])
    time.sleep(3)
    check(facts()['tasks']['codex:runtime-codex']['status']=='waiting','async acknowledgement and turn end preserve waiting')
    lingxi=HOME/'Library/Application Support/WPS 灵犀/app-server-data/state/accounts/test/sessions/runtime-lingxi/rollout.jsonl'
    append(lingxi,[{'session_id':'runtime-lingxi','type':'run.start','content':{'run_id':'r1'}},{'session_id':'runtime-lingxi','id':'ask','type':'component.start','content':json.dumps({'type':'c_ask_user_question'})},{'session_id':'runtime-lingxi','type':'run.end','content':{}}])
    wait(lambda:facts()['tasks'].get('lingxi:runtime-lingxi',{}).get('status')=='waiting')
    check(True,'real process consumes Lingxi JSONL without clearing unanswered question')
    append(lingxi,[{'session_id':'runtime-lingxi','type':'user.input','content':{}},{'session_id':'runtime-lingxi','type':'run.start','content':{'run_id':'r2'}}])
    wait(lambda:facts()['tasks']['lingxi:runtime-lingxi']['status']=='active')
    check(True,'Lingxi user response resumes work state')
    check('DO_NOT_PERSIST_THIS_PROMPT' not in json.dumps(facts()),'raw hook prompt is excluded from state')
    call('verify','--tab','agents');time.sleep(1)
    wait(lambda:(REPORT/'current-view.json').exists())
    view=json.loads((REPORT/'current-view.json').read_text())
    check(view['ui']['kind']=='agent' and 136<=view['ui']['width']<=208 and view['ui']['summaryFitsOneLine'] and view['ui']['withinViewport'] and view['ui']['height']<55 and view['ui']['borderRadius']=='18px' and view['ui']['dismissIconSize']=='12px' and view['ui']['background']=='rgba(255, 255, 255, 0.85)','Agent notification retains rounded corners with shorter body larger close icon and 85 percent opacity')
    check(view['bubble'] and any(view['source'].startswith(a) for a in ['Codex','WorkBuddy','Trae']),'actual WebView displays a source-specific notification bubble')
    call('quit');process.wait(timeout=8)
    process=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')],env=env,stdout=(REPORT/'restart.log').open('w'),stderr=subprocess.STDOUT)
    wait(lambda:call('status').get('ok'))
    check(call('status')['tasks']==5,'restart restores all five task facts')
    check(facts()['tasks']['codex:runtime-codex']['status']=='waiting','restart keeps unanswered state without replay')
finally:
    try:call('quit')
    except Exception:process.terminate()
    try:process.wait(timeout=8)
    except subprocess.TimeoutExpired:process.kill()
    (REPORT/'results.json').write_text(json.dumps({'results':results,'dataRoot':str(ROOT),'boundary':'Isolated app/CLI and fixture source test, not real Agent dispatch or session deep-link acceptance.'},ensure_ascii=False,indent=2)+'\n')
print(str(REPORT/'results.json'))
