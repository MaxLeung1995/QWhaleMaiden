import Foundation

@main struct CoreTests {
    static var passed = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        if !(try! value()) { fatalError("FAIL: "+message) }; passed += 1; print("PASS: "+message)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("starbud-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let legacyRoot=root.appendingPathComponent("legacy"),migratedRoot=root.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at:migratedRoot,withIntermediateDirectories:true)
        let legacyStore=try StateStore(url:legacyRoot.appendingPathComponent("state.sqlite"))
        let legacyCore=try PetCore(store:legacyStore);legacyCore.state.settings.waterMinutes=73;try legacyCore.save()
        try FileManager.default.createDirectory(at:legacyRoot.appendingPathComponent("logs"),withIntermediateDirectories:true)
        try Data("not-for-migration".utf8).write(to:legacyRoot.appendingPathComponent("logs/runtime.jsonl"))
        try StateStore.migrateLegacyIfNeeded(from:legacyRoot,to:migratedRoot)
        let migrated=try PetCore(store:StateStore(url:migratedRoot.appendingPathComponent("state.sqlite")))
        check(migrated.state.settings.waterMinutes==73,"rename migrates committed SQLite WAL state")
        check(!FileManager.default.fileExists(atPath:migratedRoot.appendingPathComponent("logs").path),"rename does not import legacy logs")
        legacyCore.state.settings.waterMinutes=99;try legacyCore.save()
        try StateStore.migrateLegacyIfNeeded(from:legacyRoot,to:migratedRoot)
        check((try PetCore(store:StateStore(url:migratedRoot.appendingPathComponent("state.sqlite")))).state.settings.waterMinutes==73,"rename migration is idempotent and does not overwrite new settings")
        check(FileManager.default.fileExists(atPath:legacyRoot.appendingPathComponent("state.sqlite").path),"rename preserves old user data")
        let base = Date().timeIntervalSince1970
        let store = try StateStore(url:root.appendingPathComponent("state.sqlite")); let core = try PetCore(store:store)
        let start = AgentEvent(eventId:"s",agent:.codex,sessionId:"one",turnId:"t1",type:"turn.started",sequence:1)
        check(try core.accept(start,now:base+0),"accept first event")
        check(!(try core.accept(start,now:base+0)),"replay does not apply")
        try core.accept(AgentEvent(eventId:"wait",agent:.codex,sessionId:"one",turnId:"t1",type:"attention.requested",sequence:2,requestId:"q1"),now:base+1)
        let notice = core.bubbles(now:base+2).first!
        try core.suppress(notice.id)
        try core.accept(AgentEvent(eventId:"wait-repeat",agent:.codex,sessionId:"one",turnId:"t1",type:"attention.requested",sequence:3,requestId:"q1"),now:base+3)
        check(core.bubbles(now:base+4).isEmpty,"dismissed request does not revive")
        try core.accept(AgentEvent(eventId:"wait-new",agent:.codex,sessionId:"one",turnId:"t1",type:"attention.requested",sequence:4,requestId:"q2"),now:base+5)
        check(core.bubbles(now:base+6).count == 1,"new request can notify")
        try core.accept(AgentEvent(eventId:"s2",agent:.codex,sessionId:"two",turnId:"other",type:"attention.requested",sequence:1,requestId:"q3"),now:base+6)
        check(core.bubbles(now:base+7).count == 2,"parallel sessions remain separate")
        try core.accept(AgentEvent(eventId:"next",agent:.codex,sessionId:"one",turnId:"t2",type:"turn.started",sequence:5),now:base+7)
        check(!(try core.accept(AgentEvent(eventId:"late",agent:.codex,sessionId:"one",turnId:"t1",type:"turn.ended",sequence:6),now:base+8)),"old turn cannot terminate new turn")
        let loaded = try PetCore(store:store)
        check(loaded.state.tasks["codex:one"]?.status == "active","transactional restart restores state")
        let bridgeCore=try PetCore(store:StateStore(url:root.appendingPathComponent("bridges.sqlite")))
        check(AgentID.qwenwork.bundleID == "cn.qwenwork.desktop.mac","QwenWork identity excludes Qianwen chat")
        let dshStart:[String:Any] = ["session_id":"ds","turn_id":"dt","event_id":"ds1","epoch":"e","sequence":1,"event_type":"turn/start"]
        let ds=try AgentMapping.hook(agent:.dsh,raw:dshStart)!
        try bridgeCore.accept(ds,now:base+8)
        check(bridgeCore.state.tasks["dsh:ds"]?.status == "active","DSH starts independent session")
        var draw=dshStart;draw["event_type"]="approval/asked";draw["event_id"]="ds2";draw["sequence"]=2;draw["request_id"]="dq"
        try bridgeCore.accept(AgentMapping.hook(agent:.dsh,raw:draw)!,now:base+9)
        draw["event_type"]="turn/end";draw["reason"]="completed";draw["event_id"]="ds3";draw["sequence"]=3
        check(!(try bridgeCore.accept(AgentMapping.hook(agent:.dsh,raw:draw)!,now:base+10)) && bridgeCore.state.tasks["dsh:ds"]?.status == "waiting","DSH completion cannot clear pending permission")
        draw["event_type"]="tool/result";draw["resolves_wait"]=true;draw["event_id"]="ds4";draw["sequence"]=4
        try bridgeCore.accept(AgentMapping.hook(agent:.dsh,raw:draw)!,now:base+11)
        check(bridgeCore.state.tasks["dsh:ds"]?.status == "active","DSH matching tool result resolves wait")
        var qw:[String:Any] = ["session_id":"qw","hook_event_name":"UserPromptSubmit","event_id":"qw1"]
        try bridgeCore.accept(AgentMapping.hook(agent:.qwenwork,raw:qw)!,now:base+8)
        qw["hook_event_name"]="PreToolUse";qw["tool_name"]="ask_user_question";qw["event_id"]="qw2";qw["tool_use_id"]="question-id"
        try bridgeCore.accept(AgentMapping.hook(agent:.qwenwork,raw:qw)!,now:base+9)
        qw["hook_event_name"]="Stop";qw["event_id"]="qw3"
        check(!(try bridgeCore.accept(AgentMapping.hook(agent:.qwenwork,raw:qw)!,now:base+10)) && bridgeCore.state.tasks["qwenwork:qw"]?.status == "waiting","QwenWork Stop preserves pending question")
        qw["hook_event_name"]="StopFailure"
        check(try AgentMapping.hook(agent:.qwenwork,raw:qw) == nil,"QwenWork hook failure does not become task failure")
        qw["subagent"]=true
        check(try AgentMapping.hook(agent:.qwenwork,raw:qw) == nil,"QwenWork child hooks suppressed")
        let idle: [String:Any] = ["session_id":"w","hook_event_name":"Notification","notification_type":"idle_prompt"]
        check(try AgentMapping.hook(agent:.workbuddy,raw:idle) == nil,"WorkBuddy idle is not waiting")
        check(try AgentMapping.hook(agent:.trae,raw:idle)?.type == "turn.ended","Trae idle has source-specific mapping")
        var cursor = LogCursor(offset:0,inode:1,generation:"1",session:"lx",turn:"r1")
        let ask: [String:Any] = ["session_id":"lx","type":"component.start","content":["type":"c_ask_user_question"],"id":"question"]
        check(AgentMapping.log(agent:.lingxi,raw:ask,cursor:&cursor,eventID:"a",offset:1)?.type == "attention.requested","Lingxi question start maps to waiting")
        check(AgentMapping.log(agent:.lingxi,raw:["type":"run.end"],cursor:&cursor,eventID:"b",offset:2) == nil,"Lingxi run end does not resolve pending question")
        var c = LogCursor(offset:0,inode:1,generation:"1",session:"cx",turn:"turn")
        let asyncAsk: [String:Any] = ["type":"response_item","payload":["type":"function_call","name":"functions.request_user_input_async","call_id":"a"]]
        _ = AgentMapping.log(agent:.codex,raw:asyncAsk,cursor:&c,eventID:"q",offset:1)
        let accepted: [String:Any] = ["type":"response_item","payload":["type":"function_call_output","call_id":"a","output":"{\"accepted\":true}"]]
        check(AgentMapping.log(agent:.codex,raw:accepted,cursor:&c,eventID:"out",offset:2) == nil && c.waiting,"async acknowledgement is not user answer")
        var clock = ReminderClock(); var settings = PetSettings(); settings.restEnabled = true; settings.restMinutes = 1
        check(clock.advance(seconds:60,settings:settings) == ["rest"],"rest interval emits once")
        clock.command("start"); clock.sleep()
        check(clock.focusMode == "paused" && clock.rest == 0,"sleep pauses focus and resets periodic reminders")
        check(AgentMapping.log(agent:.codex,raw:["type":"event_msg","payload":["type":"task_complete"]],cursor:&c,eventID:"end",offset:3) == nil,"Codex async wait survives turn completion")
        var sync = LogCursor(offset:0,inode:1,generation:"1",session:"sync",turn:"r")
        _ = AgentMapping.log(agent:.codex,raw:["type":"response_item","payload":["type":"function_call","name":"request_user_input","call_id":"sync-q"]],cursor:&sync,eventID:"sq",offset:1)
        check(AgentMapping.log(agent:.codex,raw:["type":"response_item","payload":["type":"function_call_output","call_id":"sync-q","output":"answer"]],cursor:&sync,eventID:"answer",offset:2)?.type == "attention.resolved","synchronous answer resumes the task")
        let logRoot=root.appendingPathComponent("logs");try FileManager.default.createDirectory(at:logRoot,withIntermediateDirectories:true)
        let log=logRoot.appendingPathComponent("history.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"incremental\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8).write(to:log)
        let consumer=LogAdapters(core:core,home:logRoot,startedAt:Date().addingTimeInterval(5))
        try consumer.consume(agent:.codex,url:log)
        check(core.state.tasks["codex:incremental"] == nil,"initial historical completion is not replayed")
        let writer=try FileHandle(forWritingTo:log);try writer.seekToEnd()
        try writer.write(contentsOf:Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"live\"}}\n".utf8))
        try consumer.consume(agent:.codex,url:log)
        check(core.state.tasks["codex:incremental"]?.status == "active","incremental append is consumed")
        let partial=Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"request_user_input\",\"call_id\":\"半行\"}}\n".utf8)
        let cut=partial.count-4;try writer.write(contentsOf:partial.prefix(cut));try consumer.consume(agent:.codex,url:log)
        check(core.state.tasks["codex:incremental"]?.status == "active","partial UTF-8 record does not advance state")
        try writer.write(contentsOf:partial.suffix(partial.count-cut));try writer.close();try consumer.consume(agent:.codex,url:log)
        check(core.state.tasks["codex:incremental"]?.status == "waiting","complete UTF-8 record is read exactly once")
        let restarted=try PetCore(store:store);let reread=LogAdapters(core:restarted,home:logRoot)
        let timestamp=restarted.state.tasks["codex:incremental"]?.updatedAt;try reread.consume(agent:.codex,url:log)
        check(restarted.state.tasks["codex:incremental"]?.updatedAt == timestamp,"persisted log cursor suppresses restart replay")
        check(!(try core.accept(AgentEvent(eventId:"s",agent:.trae,sessionId:"collision",type:"turn.started"),now:base+9)),"event identity ledger rejects cross-task duplicates")
        check(core.state.tasks["trae:collision"] == nil,"rejected duplicate rolls back projection")
        var selection=BubbleSelection()
        let first=Bubble(id:"one",category:"waiting",title:"one",summary:"one",priority:100,createdAt:1)
        let second=Bubble(id:"two",category:"waiting",title:"two",summary:"two",priority:100,createdAt:2)
        _ = selection.select([first,second],now:100);selection.lockID="one"
        check(selection.select([first,second],now:110)?.id == "one","hover lock freezes bubble identity")
        selection.lockID=nil
        check(selection.select([first,second],now:110)?.id == "two","unlocked waiting bubbles rotate fairly")
        clock.restSnooze=600
        check(clock.advance(seconds:599,settings:settings).isEmpty,"snoozed reminder does not follow normal interval")
        var restoredClock=try JSONDecoder().decode(ReminderClock.self,from:JSONEncoder().encode(clock))
        check(restoredClock.advance(seconds:1,settings:settings) == ["rest"],"snooze survives state encoding and fires once")
        check(restoredClock.advance(seconds:1,settings:settings).isEmpty,"snooze does not repeat every tick")
        try core.accept(AgentEvent(eventId:"history-ended",agent:.trae,sessionId:"offline",turnId:"offline-t",type:"turn.ended",occurredAt:base-3600),now:base)
        check(!core.bubbles(now:base).contains(where: { $0.sessionId == "offline" }),"offline historical completion is not a fresh notification")
        var focus=ReminderClock()
        check(focus.focusRemaining == 2700,"new focus defaults to 45 minutes")
        focus.command("start")
        check(focus.advance(seconds:2699,settings:PetSettings()).isEmpty && focus.focusMode == "running","focus does not finish before 45 minutes")
        check(focus.advance(seconds:1,settings:PetSettings()).count == 1 && focus.focusMode == "finished","focus finishes at the 45 minute boundary")
        core.state.reminders.focusMode="stopped";core.state.reminders.focusRemaining=1500;try core.save()
        check(try PetCore(store:store).state.reminders.focusRemaining == 2700,"existing stopped clock adopts new 45 minute default")
        core.state.reminders.focusMode="paused";core.state.reminders.focusRemaining=800;try core.save()
        check(try PetCore(store:store).state.reminders.focusRemaining == 800,"existing paused countdown is preserved")
        var deck=ChatterDeck(lines:["idle":["one","two","three"]])
        let texts=(0..<3).map { _ in deck.next("idle") }
        check(Set(texts).count == 3,"chatter completes a deck before repeating")
        check(deck.next("idle") != texts.last,"chatter does not repeat across deck boundaries")
        var taps=TripleThreeTapRecognizer()
        _=taps.feed(contacts:3,at:0);check(!taps.feed(contacts:0,at:0.1),"one three-finger tap does not exit")
        _=taps.feed(contacts:3,at:0.3);check(!taps.feed(contacts:0,at:0.4),"two three-finger taps do not exit")
        _=taps.feed(contacts:1,at:0.6);_=taps.feed(contacts:2,at:0.62);_=taps.feed(contacts:3,at:0.64)
        check(taps.feed(contacts:0,at:0.75),"third separate three-finger tap exits with staggered finger landing")
        _=taps.feed(contacts:3,at:1);_=taps.feed(contacts:0,at:1.1);_=taps.feed(contacts:3,at:3);check(!taps.feed(contacts:0,at:3.1),"widely spaced three-finger taps do not exit")
        taps.reset();_=taps.feed(contacts:3,at:0);check(!taps.feed(contacts:0,at:1),"long contact is not a tap")
        taps.reset();_=taps.feed(contacts:4,at:0);check(!taps.feed(contacts:0,at:0.1),"four-finger contact is rejected")
        let oldSettingsData=try JSONEncoder().encode(PetSettings())
        let migratedSettings=try JSONDecoder().decode(PetSettings.self,from:oldSettingsData)
        check(migratedSettings.reminderSound != false,"old settings without sound field default to gentle reminders")
        var mutedSettings=PetSettings();mutedSettings.reminderSound=false
        let mutedRoundtrip=try JSONDecoder().decode(PetSettings.self,from:JSONEncoder().encode(mutedSettings))
        check(mutedRoundtrip.reminderSound == false,"reminder sound mute survives persistence")
        check(WellnessReminder(kind:"focus",phase:"break")?.kind == "focusBreak","break completion has its own wording and animation")
        check(WellnessReminder(kind:"rest")?.animation == "超大伸懒腰" && WellnessReminder(kind:"water")?.animation == "鲸鱼吐泡泡特效","rest and water map to distinct bundled animations")
        check(WellnessReminder(kind:"unknown") == nil,"unknown reminder preview is rejected")
        print("\(passed) core checks passed")
    }
}
