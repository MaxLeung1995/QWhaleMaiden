#!/usr/bin/env python3
"""Regression: countdown/widget content must not move either tool action."""
from pathlib import Path
import json, os, subprocess, time, uuid

BASE = Path(__file__).resolve().parents[1]
APP = BASE/'build/QWhaleMaiden.app'
CLI = APP/'Contents/Helpers/starbud-event'
ROOT = BASE/'.local'/('tools-layout-'+uuid.uuid4().hex)
REPORT = BASE/'build/verification/tools-layout'
(ROOT/'home').mkdir(parents=True)
REPORT.mkdir(parents=True, exist_ok=True)
for name in ['settings.png', 'webview.json', 'current-view.json']:
    (REPORT/name).unlink(missing_ok=True)
env = dict(os.environ, STARBUD_DATA_DIR=str(ROOT/'state'), STARBUD_SOURCE_HOME=str(ROOT/'home'), STARBUD_SMOKE_DIR=str(REPORT), STARBUD_TEST_ISOLATE_MOUSE='1')
results=[]
def call(*args):
    r=subprocess.run([str(CLI), *args], env=env, text=True, capture_output=True, timeout=8)
    if r.returncode: raise RuntimeError(r.stderr)
    return json.loads(r.stdout)
def wait(fn):
    end=time.monotonic()+18
    while time.monotonic()<end:
        try:
            value=fn()
            if value:return value
        except (RuntimeError, ValueError, FileNotFoundError):pass
        time.sleep(.1)
    raise AssertionError('Startup or capture timed out')
def capture(action=None, focus=None):
    args=['verify']
    if action:args+=['--pet-ui', action]
    if focus:args+=['--focus', focus]
    response=call(*args)
    return wait(lambda:read_capture(response['captureID']))
def read_capture(capture_id):
    data=json.loads((REPORT/'current-view.json').read_text())
    return data if data['captureID']==capture_id else None
def check(condition, name):
    assert condition, name
    results.append({'name':name, 'status':'pass'})
    print('PASS: '+name, flush=True)
def stationary(data, name):
    ui=data['ui']
    check(ui['toolsLayout']==baseline['toolsLayout'] and ui['moreSize']==baseline['moreSize'], name)
    assert not ui['overlap']['more'] and not ui['overlap']['bar']
def shot(name):
    time.sleep(.15)
    (REPORT/(name+'.png')).write_bytes((REPORT/'pet-current.png').read_bytes())

p=subprocess.Popen([str(APP/'Contents/MacOS/QWhaleMaiden')], env=env, stdout=(REPORT/'app.log').open('w'), stderr=subprocess.STDOUT)
try:
    wait(lambda:call('status')['ok'])
    wait(lambda:(REPORT/'settings.png').exists())
    call('verify','--toggle','whispers')
    capture('more')
    baseline=capture('tools')['ui']
    card, left, right=baseline['toolsLayout']
    check(left['y']==right['y'] and left['height']==right['height'] and left['width']==right['width'], 'both tool buttons share top bottom and width')
    check(card['height']==112 and left['y']-card['y']-card['height']==8, 'card reserves fixed space above button row')
    shot('countdown')
    empty=capture('widgets')
    stationary(empty, 'unconfigured weather calendar leaves both buttons stationary')
    shot('weather-empty')
    stationary(capture('widgets'), 'return from empty widgets leaves both buttons stationary')
    capture('widgetFixture')
    configured=capture('widgets')
    check('上海' in configured['ui']['weatherText'] and '今日测试日程' in configured['ui']['todayCalendar'], 'configured sample weather and today event render')
    stationary(configured, 'configured widgets leave both buttons stationary')
    shot('weather-configured')
    for focus in ['start', 'pause', 'resume', 'cancel']:
        stationary(capture(focus=focus), 'timer '+focus+' leaves widget action row stationary')
    stationary(capture('clearWidgetFixture'), 'clearing configured data keeps action row stationary')
    for index in range(4):
        stationary(capture('widgets'), 'repeated toggle '+str(index+1)+' keeps identical coordinates')
    time.sleep(1.2)
    stationary(capture(), 'periodic native snapshot refresh keeps identical coordinates')
finally:
    try:call('quit')
    except Exception:p.terminate()
    p.wait(timeout=8)
    (REPORT/'results.json').write_text(json.dumps({'results':results, 'dataRoot':str(ROOT), 'baseline':locals().get('baseline'), 'boundary':'Isolated WKWebView, sample weather/calendar, no personal calendar access'}, ensure_ascii=False, indent=2)+'\n')
print(str(REPORT/'results.json'))
