import AppKit
import WebKit
import ServiceManagement
import Darwin

final class PetPanel: NSPanel {
    var acceptsMenuKeys=false
    override var canBecomeKey: Bool { acceptsMenuKeys }
    // The transparent surface may cross the menu bar; body bounds are enforced explicitly.
    override func constrainFrameRect(_ frameRect: NSRect,to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct QWhaleMaidenApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var core: PetCore!
    var packs: AssetPackManager!
    var adapters: LogAdapters!
    var channel: EventServer!
    let weather = WeatherService()
    let calendar = CalendarService()
    let passThroughExit = PassThroughExit()
    var window: PetPanel!
    var petView: WKWebView!
    var settingsWindow: NSWindow?
    var settingsView: WKWebView?
    var pendingSettingsTab: String?
    var statusItem: NSStatusItem!
    var timer: Timer?
    var selection = BubbleSelection()
    var displayed: Bubble?
    var presentedReminders: [String] = []
    var reminderAudio: NSSound?
    var pressed: Bubble?
    var shownAt: Double = 0
    var inputBusy = false
    var through = false
    var menusOnRight=false
    var hidden = false
    var hitRegions: [NSRect] = []
    var menuRegions: [NSRect] = []
    var menuGlobalMonitor: Any?
    var menuLocalMonitor: Any?
    var motion=PetMotion()
    var motionTimer: Timer?
    var motionUptime=ProcessInfo.processInfo.systemUptime
    var motionReportAt=ProcessInfo.processInfo.systemUptime
    var motionFrames=0
    var motionMaxFrameMS: Double=0
    var lastGeometryLog=""
    var lastPositionConstraintLog: Double=0
    var lastHealthLog=ProcessInfo.processInfo.systemUptime
    var recentErrors=Set<String>()
    lazy var runtimeLog=RuntimeLog(directory:dataRoot.appendingPathComponent("logs"))
    var smokeWidgetFixture=false
    var lockFD: Int32 = -1
    var lastTick = ProcessInfo.processInfo.systemUptime
    var nextWalk: Double = 0
    var nextWhisper: Double = 0
    var observers: [NSObjectProtocol] = []
    var currentPack: InstalledPack?
    var packList: [InstalledPack] = []
    var cities: [WeatherCity] = []
    var info = ""
    var chatter: ChatterDeck!
    let dataRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STARBUD_DATA_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QWhaleMaiden/v1").path)
    var smokeDirectory: URL? { ProcessInfo.processInfo.environment["STARBUD_SMOKE_DIR"].map { URL(fileURLWithPath:$0) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at:dataRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            lockFD = open(dataRoot.appendingPathComponent("instance.lock").path,O_CREAT|O_RDWR,0o600)
            guard lockFD >= 0, flock(lockFD,LOCK_EX|LOCK_NB) == 0 else {
                _ = try? LocalChannel.request(path:LocalChannel.path(dataRoot:dataRoot),object:["command":"show"]); NSApp.terminate(nil); return
            }
            runtimeLog.record("app_start",["version":"0.1.2","pid":ProcessInfo.processInfo.processIdentifier])
            chatter = try ChatterDeck(url:Bundle.main.resourceURL!.appendingPathComponent("chatter.json"))
            if ProcessInfo.processInfo.environment["STARBUD_DATA_DIR"] == nil {
                let legacyName="\u{661F}\u{82BD}\u{684C}\u{5BA0}"
                let legacyRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/"+legacyName+"/v1")
                try StateStore.migrateLegacyIfNeeded(from:legacyRoot,to:dataRoot)
            }
            core = try PetCore(store:StateStore(url:dataRoot.appendingPathComponent("state.sqlite")))
            // Old prototype ledger is preserved, not imported into the new state model.
            let legacy = dataRoot.deletingLastPathComponent().appendingPathComponent("state.json")
            let backup = dataRoot.appendingPathComponent("legacy-state.backup.json")
            if FileManager.default.fileExists(atPath:legacy.path), !FileManager.default.fileExists(atPath:backup.path) { try FileManager.default.copyItem(at:legacy,to:backup) }
            core.state.reminders.command("pause")
            try core.save()
            packs = try AssetPackManager(root:dataRoot.appendingPathComponent("packs")); refreshPacks()
            adapters = LogAdapters(core:core,home:ProcessInfo.processInfo.environment["STARBUD_SOURCE_HOME"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser)
            for agent in [AgentID.dsh,.qwenwork] { adapters.report[agent.rawValue]=BridgeSetup.status(agent:agent,home:adapters.home) }
            channel = EventServer(path:LocalChannel.path(dataRoot:dataRoot)); channel.handler = { [weak self] object in self?.handleIPC(object) ?? ["ok":false] }; try channel.start()
            setupWindow(); setupMenu(); observeLifecycle();startMotionTimer()
            core.onAccepted = { [weak self] event in
                if let self=self,[.dsh,.qwenwork].contains(event.agent) { self.adapters.report[event.agent.rawValue]="已收到宿主事件 · "+DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.short) }
                guard let self=self,self.core.state.settings.quietUntil <= Date().timeIntervalSince1970,!self.hidden,self.core.activity != "wait" else { return }
                if let occurred=event.occurredAt,Date().timeIntervalSince1970-occurred>60 { return }
                if event.type == "turn.ended" { self.runPet("command",["name":"celebrate"]) }
                else if event.type == "task.failed" { self.runPet("command",["name":"error"]) }
            }
            calendar.changed = { [weak self] in guard let self = self else { return }; self.calendar.refresh(core:self.core); self.publish() }
            calendar.refresh(core:core)
            adapters.poll(forceScan:true)
            nextWalk = Date().timeIntervalSince1970 + Double.random(in:40...90)
            nextWhisper = Date().timeIntervalSince1970 + Double.random(in:30...60)
            timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.tick() }
            weather.refresh(core:core) { [weak self] in self?.publish() }
            publish()
            if smokeDirectory != nil { scheduleSmoke() }
        } catch {
            let alert = NSAlert(); alert.messageText = "QWhaleMaiden启动失败"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPet(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        runtimeLog.record("app_stop");motionTimer?.invalidate();runtimeLog.flush();passThroughExit.stop();stopMenuMonitors();timer?.invalidate(); channel?.stop()
        if let core = core { core.state.reminders.command("pause"); try? core.save() }
        if lockFD >= 0 { flock(lockFD,LOCK_UN); close(lockFD) }
    }
    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self,name:"starbud")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.setURLSchemeHandler(AssetScheme(packs:packs),forURLScheme:"starbud-asset")
        let view = WKWebView(frame:.zero,configuration:configuration)
        view.setValue(false,forKey:"drawsBackground"); view.underPageBackgroundColor = .clear
        view.navigationDelegate = self; view.allowsMagnification = false
        return view
    }
    func petAnchor(_ scale:Double,onRight:Bool) -> Double { let half=111.158*scale/2;return 260+max(66,half) }
    func petPanelSize(_ scale:Double) -> NSSize { let half=111.158*scale/2;return NSSize(width:2*(260+max(66,half)),height:590+131.984*scale) }
    func setupWindow() {
        let scale = core.state.settings.size
        menusOnRight=core.state.settings.menusOnRight ?? false
        let dimensions=petPanelSize(scale)
        window = PetPanel(contentRect:NSRect(x:0,y:0,width:dimensions.width,height:dimensions.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; window.isMovableByWindowBackground = false
        petView = makeWebView(); window.contentView = petView
        if let x=core.state.settings.x,let y=core.state.settings.y {
            var origin=x
            if core.state.settings.layoutVersion != 9 {
                let oldLane=max(320,296.421*scale+24)
                let oldAnchor=core.state.settings.layoutVersion == 8 ? (menusOnRight ? max(122,111.158*scale/2+8) : 260+max(66,111.158*scale/2)) : core.state.settings.layoutVersion == 7 ? (menusOnRight ? max(122,111.158*scale/2+8) : 260+max(66,111.158*scale/2)) : core.state.settings.layoutVersion == 6 ? (menusOnRight ? max(66,111.158*scale/2)+8 : 260+max(66,111.158*scale/2)) : core.state.settings.layoutVersion == 5 ? (menusOnRight ? max(66,111.158*scale/2)+8 : 260+111.158*scale/2) : core.state.settings.layoutVersion == 4 ? (menusOnRight ? max(74,111.158*scale/2)+8 : 260+111.158*scale/2) : core.state.settings.layoutVersion == 3 ? (menusOnRight ? oldLane/2 : 260+oldLane/2) : max(320,300*scale)/2
                origin+=oldAnchor-petAnchor(scale,onRight:menusOnRight)
            }
            window.setFrameOrigin(NSPoint(x:origin,y:y-((core.state.settings.layoutVersion ?? 0)>=8 ? 0 : 278)))
        }
        else { moveCorner() }
        core.state.settings.layoutVersion=9
        ensureVisible();savePosition()
        let url = Bundle.main.resourceURL!.appendingPathComponent("index.html")
        petView.loadFileURL(url,allowingReadAccessTo:Bundle.main.resourceURL!)
        window.orderFrontRegardless()
        // Poll is local coordinate-only; no global key monitoring or Accessibility permission.
        let hitTimer = Timer.scheduledTimer(withTimeInterval:0.06,repeats:true) { [weak self] _ in self?.updateHitTesting() }
        RunLoop.main.add(hitTimer,forMode:.common)
    }
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let icon=NSImage(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("dsh/avatar.png")) { icon.size=NSSize(width:22,height:22);statusItem.button?.image=icon } else { statusItem.button?.title = "✦" }; statusItem.button?.toolTip = "QWhaleMaiden"
        statusItem.isVisible = false
        rebuildMenu()
    }
    func rebuildMenu() {
        let menu = NSMenu()
        func item(_ title: String, _ selector: Selector) { let i = NSMenuItem(title:title,action:selector,keyEquivalent:""); i.target = self; menu.addItem(i) }
        item(hidden ? "显示桌宠" : "隐藏桌宠",#selector(toggleHidden))
        item(core.state.settings.quietUntil > Date().timeIntervalSince1970 ? "结束勿扰" : "勿扰 1 小时",#selector(toggleQuiet))
        item(through ? "关闭整窗穿透" : "整窗穿透",#selector(toggleThrough))
        item("回到可见屏幕",#selector(corner)); item("设置与生活挂件…",#selector(openSettings))
        menu.addItem(.separator()); item("开始 45 分钟番茄钟",#selector(startFocus)); item("暂停/继续番茄钟",#selector(pauseFocus)); item("取消番茄钟",#selector(cancelFocus))
        menu.addItem(.separator()); item("唤醒",#selector(wakePet)); item("睡觉",#selector(sleepPet))
        menu.addItem(.separator()); item("退出QWhaleMaiden",#selector(quit)); statusItem.menu = menu
    }
    @objc func toggleHidden() { stopNativeMotion("visibility_toggle");hidden.toggle(); hidden ? window.orderOut(nil) : window.orderFrontRegardless(); rebuildMenu() }
    func showPet() { hidden = false; through = false;passThroughExit.stop(); window?.orderFrontRegardless(); updateHitTesting(); rebuildMenu() }
    @objc func toggleQuiet() { core.state.settings.quietUntil = core.state.settings.quietUntil > Date().timeIntervalSince1970 ? 0 : Date().timeIntervalSince1970+3600; save(); rebuildMenu(); publish() }
    func endThrough() { through=false;passThroughExit.stop();inputBusy=false;updateHitTesting();rebuildMenu();publish() }
    @objc func toggleThrough() {
        stopNativeMotion("through_toggle");runtimeLog.record("through_toggle",["wasEnabled":through])
        if through { endThrough();return }
        guard passThroughExit.begin(onExit:{ [weak self] in self?.endThrough() }) else { info="恢复快捷键注册失败，未开启穿透";publish();return }
        through=true;inputBusy=false;updateHitTesting();rebuildMenu();info="三指连续轻点三次退出穿透；备用 Control+Option+Command+P";publish()
    }
    @objc func corner() { stopNativeMotion("recall");moveCorner(); ensureVisible(); savePosition() }
    @objc func startFocus() { reminderCommand("start") }
    @objc func pauseFocus() { reminderCommand(core.state.reminders.focusMode == "running" ? "pause" : "resume") }
    @objc func cancelFocus() { reminderCommand("cancel") }
    @objc func wakePet() { showPet(); runPet("command",["name":"wake"]) }
    @objc func sleepPet() { runPet("command",["name":"sleep"]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openSettings() {
        if let window = settingsWindow { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); publish(); return }
        let panel = NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:690),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        panel.title = "QWhaleMaiden · 设置与生活"; panel.minSize = NSSize(width:700,height:520); panel.isReleasedWhenClosed = false
        let view = makeWebView(); panel.contentView = view; settingsWindow = panel; settingsView = view
        let url = Bundle.main.resourceURL!.appendingPathComponent("settings.html"); view.loadFileURL(url,allowingReadAccessTo:Bundle.main.resourceURL!)
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func moveCorner() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        window.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-window.frame.width-24,y:screen.visibleFrame.minY-258))
    }
    func bodyRect() -> NSRect {
        let scale=core.state.settings.size
        if currentPack != nil,let rect=hitRegions.first,rect.width>0,rect.height>0 { return rect }
        return NSRect(x:petAnchor(scale,onRight:menusOnRight)-111.158*scale/2,y:window.frame.height-320-131.984*scale,width:111.158*scale,height:131.984*scale)
    }
    func bodyScreenRect() -> [Double] {
        let b=bodyRect();return [window.frame.minX+b.minX,window.frame.maxY-b.maxY,b.width,b.height]
    }
    func motionScreen() -> NSScreen? {
        let screens=NSScreen.screens,b=bodyRect()
        let body=NSRect(x:window.frame.minX+b.minX,y:window.frame.maxY-b.maxY,width:b.width,height:b.height)
        guard let index=MotionBounds.screenIndex(frames:screens.map(\.frame),body:body,cursor:motion.isGrabbing ? NSEvent.mouseLocation : nil) else { return nil }
        return screens[index]
    }
    func motionBounds(_ screen: NSScreen) -> MotionBounds {
        MotionBounds.forScreen(screen.visibleFrame,body:bodyRect(),windowHeight:window.frame.height)
    }
    func ensureVisible(preserveMotionPosition: Bool=false) {
        guard window != nil,let screen=motionScreen() else { return }
        let f=screen.visibleFrame;var w=window.frame;var flipped=false
        let center=w.minX+petAnchor(core.state.settings.size,onRight:menusOnRight)
        let oldAnchor=petAnchor(core.state.settings.size,onRight:menusOnRight)
        if w.minX<f.minX && !menusOnRight && center<f.midX { menusOnRight=true;flipped=true }
        else if w.maxX>f.maxX && menusOnRight && center>=f.midX { menusOnRight=false;flipped=true }
        if flipped {
            let shift=oldAnchor-petAnchor(core.state.settings.size,onRight:menusOnRight)
            w.origin.x+=shift;motion.translate(x:shift);core.state.settings.menusOnRight=menusOnRight
            runtimeLog.record("menu_side_changed",["right":menusOnRight,"phase":motion.phase.rawValue])
        }
        let bounds=motionBounds(screen),point=bounds.clamp(w.origin)
        if hypot(window.frame.minX-point.x,window.frame.minY-point.y)>0.01 { window.setFrameOrigin(point) }
        // AppKit rounds rendered origins; retaining subpixels keeps left/right speeds symmetric.
        if motion.active { motion.position=preserveMotionPosition ? bounds.clamp(motion.position) : window.frame.origin }
        let geometry="\(bounds.minX),\(bounds.maxX),\(bounds.minY),\(bounds.maxY),\(menusOnRight)"
        if geometry != lastGeometryLog { lastGeometryLog=geometry;runtimeLog.record("motion_bounds",["bounds":[bounds.minX,bounds.maxX,bounds.minY,bounds.maxY],"body":[bodyRect().minX,bodyRect().minY,bodyRect().width,bodyRect().height],"screen":[f.minX,f.minY,f.width,f.height]]) }
        if flipped { publish() }
    }
    func startMotionTimer() {
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.advanceMotion() }
        motionTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    var menuBlockedUntil:Double=0
    var screenSignature=""
    func refreshScreenGeometry() {
        let signature=NSScreen.screens.map { "\($0.frame)|\($0.visibleFrame)|\($0.backingScaleFactor)" }.joined(separator:";")
        guard signature != screenSignature else { return };screenSignature=signature
        stopNativeMotion("screen_geometry_changed");ensureVisible();savePosition();publish()
        runtimeLog.record("screen_geometry_changed",["count":NSScreen.screens.count])
    }
    func beginGrab() {
        guard !through else { return }
        menuBlockedUntil=ProcessInfo.processInfo.systemUptime+0.7;runPet("command",["name":"nativeMotionStarted"])
        motion.grab(position:window.frame.origin,cursor:NSEvent.mouseLocation,now:ProcessInfo.processInfo.systemUptime)
        inputBusy=true;motionUptime=ProcessInfo.processInfo.systemUptime;motionFrames=0;motionMaxFrameMS=0;motionReportAt=motionUptime
        runtimeLog.record("drag_press",motionFields());updateHitTesting()
    }
    func releaseGrab() {
        guard motion.isGrabbing else { return }
        menuBlockedUntil=ProcessInfo.processInfo.systemUptime+0.7
        let dragged=motion.release(now:ProcessInfo.processInfo.systemUptime,throwsEnabled:!core.state.settings.reducedMotion)
        runtimeLog.record(dragged ? "drag_release" : "pet_tap",motionFields())
        runPet("command",["name":"nativeRelease","dragged":dragged,"flung":motion.phase == .flight])
        inputBusy=motion.active;updateHitTesting();if !inputBusy { savePosition() }
    }
    func stopNativeMotion(_ reason: String) {
        guard motion.active else { return };menuBlockedUntil=ProcessInfo.processInfo.systemUptime+0.7;runtimeLog.record("motion_stopped",motionFields().merging(["reason":reason]) { _,new in new });motion.stop();inputBusy=false
        runPet("command",["name":"nativeMotionStopped"]);updateHitTesting();savePosition()
    }
    func chooseRunDirection() -> Double {
        guard let screen=motionScreen() else { return Bool.random() ? -1 : 1 }
        return PetMotion.walkDirection(position:window.frame.origin,bounds:motionBounds(screen),randomDirection:Bool.random() ? -1 : 1)
    }
    func startWalk() {
        guard !motion.isGrabbing,!core.state.settings.reducedMotion,core.state.settings.walk else { return }
        let direction=chooseRunDirection()
        runPet("command",["name":"nativeMotionStarted"]);motion.walk(position:window.frame.origin,direction:direction);inputBusy=true;resetMotionTelemetry()
        runPet("command",["name":"nativeWalkDirection","direction":direction,"remaining":motion.walkRemaining]);runtimeLog.record("walk_start",motionFields())
    }
    func motionFields() -> [String:Any] { ["phase":motion.phase.rawValue,"x":window.frame.minX,"y":window.frame.minY,"vx":motion.velocity.x,"vy":motion.velocity.y,"through":through] }
    func advanceMotion() {
        let now=ProcessInfo.processInfo.systemUptime,elapsed=now-motionUptime;motionUptime=now
        guard motion.active,let screen=motionScreen() else { return }
        motionFrames+=1;motionMaxFrameMS=max(motionMaxFrameMS,elapsed*1000)
        var collisions:[String]=[]
        let oldDirection=motion.velocity.x
        let oldPhase=motion.phase
        if motion.isGrabbing {
            if motion.follow(cursor:NSEvent.mouseLocation,now:now,bounds:motionBounds(screen)) { runtimeLog.record("drag_start",motionFields());runPet("command",["name":"nativeDragStarted"]) }
            if NSEvent.pressedMouseButtons & 1 == 0 { releaseGrab() }
        } else {
            collisions=motion.advance(seconds:elapsed,bounds:motionBounds(screen))
        }
        if oldPhase == .walk && motion.phase == .walk && oldDirection*motion.velocity.x<0 {
            runPet("command",["name":"nativeWalkDirection","direction":motion.velocity.x<0 ? -1 : 1,"remaining":motion.walkRemaining]);runtimeLog.record("walk_turn",motionFields())
        }
        let requested=motion.position
        window.setFrameOrigin(requested)
        if hypot(window.frame.minX-requested.x,window.frame.minY-requested.y)>1.5,now-lastPositionConstraintLog>1 {
            lastPositionConstraintLog=now;runtimeLog.record("window_position_constrained",level:"warning",["requested":[Double(requested.x),Double(requested.y)],"actual":[Double(window.frame.minX),Double(window.frame.minY)]])
        }
        ensureVisible(preserveMotionPosition:true);updateHitTesting()
        for edge in collisions { runtimeLog.record(edge == "invalid_motion" ? "motion_invalid" : edge.contains("settled") ? "motion_settled" : "motion_collision",level:edge == "invalid_motion" ? "error" : "info",motionFields().merging(["edge":edge]) { _,new in new }) }
        if now-motionReportAt>=1 { runtimeLog.record("motion_sample",motionFields().merging(["frames":motionFrames,"elapsed":now-motionReportAt,"maxFrameMS":motionMaxFrameMS]) { _,new in new });motionFrames=0;motionMaxFrameMS=0;motionReportAt=now }
        if oldPhase != .idle && !motion.active { menuBlockedUntil=now+0.7;inputBusy=false;runPet("command",["name":"nativeMotionStopped"]);savePosition();publish() }
    }
    func savePosition() { core.state.settings.x = window.frame.minX; core.state.settings.y = window.frame.minY; save() }
    func updateHitTesting() {
        guard window != nil else { return }
        let local = window.convertPoint(fromScreen:NSEvent.mouseLocation)
        let domPoint = NSPoint(x:local.x,y:window.frame.height-local.y)
        let hit = hitRegions.contains { $0.contains(domPoint) }
        window.ignoresMouseEvents = through || (!motion.isGrabbing && !hit)
    }
    func stopMenuMonitors() {
        if let monitor=menuGlobalMonitor { NSEvent.removeMonitor(monitor);menuGlobalMonitor=nil }
        if let monitor=menuLocalMonitor { NSEvent.removeMonitor(monitor);menuLocalMonitor=nil }
    }
    func watchMenuClicks() {
        guard !menuRegions.isEmpty else { stopMenuMonitors();return }
        let mask:NSEvent.EventTypeMask=[.leftMouseDown,.rightMouseDown,.otherMouseDown]
        if menuGlobalMonitor == nil { menuGlobalMonitor=NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] event in
            if self?.smokeDirectory != nil && ProcessInfo.processInfo.environment["STARBUD_TEST_ISOLATE_MOUSE"] == "1" { return }
            self?.dismissMenuIfOutside(NSEvent.mouseLocation,rightClick:event.type == .rightMouseDown)
        } }
        if menuLocalMonitor == nil { menuLocalMonitor=NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] event in
            if self?.smokeDirectory != nil && ProcessInfo.processInfo.environment["STARBUD_TEST_ISOLATE_MOUSE"] == "1" { return event }
            self?.dismissMenuIfOutside(NSEvent.mouseLocation,rightClick:event.type == .rightMouseDown);return event
        } }
    }
    func dismissMenuIfOutside(_ point:NSPoint,rightClick:Bool=false) {
        guard !menuRegions.isEmpty else { return }
        let local=window.convertPoint(fromScreen:point),dom=NSPoint(x:local.x,y:window.frame.height-local.y)
        if menuRegions.contains(where:{ $0.contains(dom) }) { return }
        // A right click on the pet is its explicit open gesture.
        if rightClick,hitRegions.first?.contains(dom) == true { return }
        menuRegions=[];stopMenuMonitors();runPet("command",["name":"dismissUI"])
    }
    func observeLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self = self else { return }; self.core.state.reminders.sleep(); self.save(); self.runPet("command",["name":"pauseMotion"])
        })
        observers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self = self else { return }; self.lastTick = ProcessInfo.processInfo.systemUptime; self.core.state.reminders.sleep(); self.calendar.refresh(core:self.core); self.ensureVisible(); self.runPet("command",["name":"wake"]); self.publish()
        })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.refreshScreenGeometry() })
    }
    func tick() {
        refreshScreenGeometry()
        let uptime = ProcessInfo.processInfo.systemUptime;
        if uptime-lastHealthLog>=30 { lastHealthLog=uptime;runtimeLog.record("health",motionFields().merging(["hidden":hidden,"menuOpen":!menuRegions.isEmpty]) { _,new in new }) }
        if let error=weather.error,recentErrors.insert(error).inserted { runtimeLog.record("weather_error",level:"warning",["message":String(error.prefix(200))]) }
 let dt = max(0,min(5,uptime-lastTick)); lastTick = uptime
        let now = Date().timeIntervalSince1970
        let reminders = core.state.reminders.advance(seconds:dt,settings:core.state.settings)
        for kind in reminders {
            addWellnessReminder(kind:kind.hasPrefix("focus:") ? "focus" : kind, phase:core.state.reminders.focusPhase)
        }
        if !reminders.isEmpty || Int(now) % 30 == 0 { save() }
        if Int(now) % 2 == 0 { adapters.poll() }
        if Int(now) % 60 == 0 { calendar.refresh(core:core); weather.refresh(core:core) { [weak self] in self?.publish() } }
        calendar.tick(core:core,now:now)
        if now >= nextWalk { nextWalk = now+Double.random(in:40...90); if core.state.settings.walk && !core.state.settings.reducedMotion && core.activity == "idle" && !inputBusy && !hidden && core.state.settings.quietUntil <= now { runPet("command",["name":"walk"]) } }
        if now >= nextWhisper {
            nextWhisper = now+Double.random(in:120...240)
            if core.state.settings.whispers && core.activity == "idle" && !inputBusy && !hidden && core.state.settings.quietUntil <= now { emitWhisper() }
        }
        let items = core.bubbles(now:now)
        if let displayed = displayed, displayed.category != "waiting", selection.lockID == nil, now-shownAt >= 8 {
            do { try core.suppress(displayed.id) } catch { info = error.localizedDescription }
            self.displayed = nil; selection.selectedID = nil
        }
        let eligible = core.bubbles(now:now)
        let next = selection.select(eligible,now:now)
        if next?.id != displayed?.id { shownAt = now }
        displayed = next
        statusItem.button?.title = core.state.settings.quietUntil > now ? "✦◦" : (items.contains(where: { $0.category == "waiting" }) ? "✦•" : "✦")
        publish()
        presentWellnessReminder()
    }
    func addWellnessReminder(kind:String,phase:String="work",preview:Bool=false) {
        guard let style=WellnessReminder(kind:kind,phase:phase) else { return }
        if preview { core.ephemeral.removeAll { $0.id.hasPrefix("preview-reminder:") } }
        core.addBubble(id:(preview ? "preview-reminder:" : "reminder:")+style.kind+":"+UUID().uuidString,category:style.category,title:style.title,summary:style.message,priority:style.priority,action:style.category,lifetime:60)
    }
    func previewWellnessReminder(_ kind:String) {
        guard WellnessReminder(kind:kind) != nil else { return }
        addWellnessReminder(kind:kind,preview:true);tick()
    }
    func presentWellnessReminder() {
        guard let bubble=displayed,["focus","rest","water"].contains(bubble.category),!presentedReminders.contains(bubble.id),!hidden,!inputBusy,core.state.settings.quietUntil<=Date().timeIntervalSince1970,
              let style=WellnessReminder(kind:bubble.category,phase:bubble.title == "休息结束" ? "break" : "work") else { return }
        presentedReminders.append(bubble.id);if presentedReminders.count>128 { presentedReminders.removeFirst(presentedReminders.count-128) }
        let animate = !core.state.settings.reducedMotion && core.activity == "idle"
        if animate { runPet("command",["name":"reminderFeedback","action":style.animation]) }
        var played=false
        if core.state.settings.reminderSound != false,let url=Bundle.main.resourceURL?.appendingPathComponent("sounds/"+style.sound+".wav"),let sound=NSSound(contentsOf:url,byReference:false) {
            reminderAudio?.stop();reminderAudio=sound;sound.volume=0.45;played=sound.play()
        }
        runtimeLog.record("reminder_feedback",["kind":style.kind,"soundPlayed":played,"animationRequested":animate])
    }
    func refreshPacks() { packList = packs.list(); currentPack = packList.first { $0.id == core.state.settings.selectedPack } }
    func overlayViewport() -> [String:Double] {
        guard let screen=motionScreen() else { return [:] };let f=screen.visibleFrame,w=window.frame
        return ["left":max(0,f.minX-w.minX),"right":min(w.width,f.maxX-w.minX),"top":max(0,w.maxY-f.maxY),"bottom":min(w.height,w.maxY-f.minY)]
    }
    func resetMotionTelemetry() { motionUptime=ProcessInfo.processInfo.systemUptime;motionReportAt=motionUptime;motionFrames=0;motionMaxFrameMS=0 }
    func geometrySnapshot() -> [String:Double] {
        guard let screen=motionScreen() else { return [:] };let b=motionBounds(screen)
        return ["x":window.frame.minX,"y":-window.frame.minY,"minX":b.minX,"maxX":b.maxX,"minY":-b.maxY,"maxY":-b.minY]
    }
    func snapshot() -> [String:Any] {
        func encoded<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(value))) ?? NSNull() }
        let items = core.bubbles()
        let agents: [[String:Any]] = AgentID.allCases.map { a in
            ["id":a.rawValue,"name":a.name,"installed":LaunchRouter.appURL(a) != nil,"enabled":!core.state.settings.disabledAgents.contains(a),"status":adapters.report[a.rawValue] ?? ([.dsh,.qwenwork].contains(a) ? BridgeSetup.status(agent:a,home:adapters.home) : "需安装 hook；模式覆盖待真实验证"),"navigation":"打开应用 · 会话定位未启用"]
        }
        var result:[String:Any] = ["menusOnRight":menusOnRight,"through":through,"escape":passThroughExit.status,"chatter":chatter.lines,"settings":encoded(core.state.settings),"activity":core.activity,"bubble":encoded(displayed),"count":items.count,"index":(items.firstIndex { $0.id == displayed?.id } ?? 0)+1,"reminders":encoded(core.state.reminders),"weather":encoded(core.state.weather),"weatherError":weather.error ?? "","calendar":encoded(calendar.items),"calendars":calendar.calendars,"calendarStatus":calendar.status,"packs":encoded(packList),"pack":encoded(currentPack),"agents":agents,"cities":encoded(cities),"info":info,"loginEnabled":SMAppService.mainApp.status == .enabled,"version":"0.1.2","geometry":geometrySnapshot(),"overlayViewport":overlayViewport()]
        if smokeDirectory != nil && smokeWidgetFixture {
            var settings=result["settings"] as! [String:Any];settings["calendarEnabled"]=true;settings["city"]=["name":"上海","latitude":31.23,"longitude":121.47,"timezone":"Asia/Shanghai"];result["settings"]=settings
            let start=Calendar.current.startOfDay(for:Date()).timeIntervalSince1970
            result["weather"]=["city":"上海","temperature":23.4,"code":1,"validAt":"2026-10-21T10:00","fetchedAt":Date().timeIntervalSince1970]
            result["calendar"]=[["id":"today","title":"今日测试日程","start":start+36000,"end":start+39600,"allDay":false],["id":"tomorrow","title":"明日测试日程","start":start+129600,"end":start+133200,"allDay":false]]
            result["calendarStatus"]="只读 · 1 个日历"
        }
        return result
    }
    func publish() {
        guard core != nil else { return }
        let object = snapshot()
        guard let data = try? JSONSerialization.data(withJSONObject:object,options:[.fragmentsAllowed]), let json = String(data:data,encoding:.utf8) else { return }
        petView?.evaluateJavaScript("window.render && window.render(\(json))",completionHandler:nil)
        settingsView?.evaluateJavaScript("window.render && window.render(\(json))",completionHandler:nil)
    }
    func runPet(_ method: String, _ object: [String:Any]) {
        if method == "command",object["name"] as? String == "pauseMotion" { stopNativeMotion("pause_command") }

        guard let data = try? JSONSerialization.data(withJSONObject:object), let json = String(data:data,encoding:.utf8) else { return }
        petView?.evaluateJavaScript("window.\(method) && window.\(method)(\(json))") { [weak self] _,error in if let error=error { self?.runtimeLog.record("web_command_error",level:"error",["method":method,"message":String(error.localizedDescription.prefix(200))]) } }
    }
    func save() { do { try core.save() } catch { info = "保存失败："+error.localizedDescription } }
    func reminderCommand(_ name: String) { core.state.reminders.command(name);if ["start","break","cancel"].contains(name) { core.ephemeral.removeAll { $0.category == "focus" } };save();publish() }
    func openBubble(_ id: String) {
        guard let bubble = (pressed?.id == id ? pressed : nil) ?? (displayed?.id == id ? displayed : nil) else { return }
        if bubble.id.hasPrefix("preview-reminder:") { try? core.suppress(id);selection.lockID=nil;pressed=nil;tick();return }
        if let agent = bubble.agent {
            LaunchRouter.open(agent) { [weak self] error in
                guard let self = self else { return }
                if let error = error { self.info = "打开失败："+error.localizedDescription; self.core.addBubble(category:"error",title:agent.name,summary:"打开失败，请在设置中检查应用",priority:99,lifetime:20) }
                else { do { try self.core.suppress(id) } catch { self.info = error.localizedDescription } }
                self.pressed = nil; self.selection.lockID = nil; self.tick()
            }
        } else {
            if bubble.action == "calendar" { LaunchRouter.calendar() }
            else if bubble.action == "focus" { pendingSettingsTab="life";openSettings();selectSettingsTab() }
            else if let action = bubble.action { core.state.reminders.command(action) }
            do { try core.suppress(id) } catch { info = error.localizedDescription }; selection.lockID = nil; pressed = nil; tick()
        }
    }
    func handleIPC(_ object: [String:Any]) -> [String:Any] {
        do {
            switch object["command"] as? String {
            case "ping": return ["ok":true]
            case "show": showPet(); return ["ok":true]
            case "previewReminder":
                guard let kind=object["kind"] as? String,WellnessReminder(kind:kind) != nil else { throw QWhaleMaidenError.message("未知提醒类型") }
                previewWellnessReminder(kind);return ["ok":true]
            case "quit": DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { NSApp.terminate(nil) };return ["ok":true]
            case "status": return ["bodyScreenRect":bodyScreenRect(),"motion":motionFields(),"geometry":geometrySnapshot(),"overlayViewport":overlayViewport(),"logDirectory":runtimeLog.directory.path,"ok":true,"version":"0.1.2","tasks":core.state.tasks.count,"bubbles":core.bubbles().count,"hitRegions":hitRegions.count,"statusIconVisible":statusItem.isVisible,"menuClickMonitoring":menuGlobalMonitor != nil && menuLocalMonitor != nil,"through":through,"escape":passThroughExit.status,"adapters":adapters.report,"dataRoot":dataRoot.path]
            case "verifyView":
                let captureID=(object["captureID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
                guard smokeDirectory != nil else { throw QWhaleMaidenError.message("仅隔离验证实例可用") }
                if let tab=object["tab"] as? String,["companion","agents","life","widgets","packs"].contains(tab) { openSettings();settingsView?.evaluateJavaScript("document.querySelector('[data-tab=\"\(tab)\"]').click()",completionHandler:nil) }
                if let toggle=object["toggle"] as? String,["preview","walk","whispers","reducedMotion","restEnabled","waterEnabled","reminderSound"].contains(toggle) { settingsView?.evaluateJavaScript("(()=>{let e=document.querySelector('[data-setting=\"\(toggle)\"]');e.checked=!e.checked;e.dispatchEvent(new Event('change',{bubbles:true}))})()",completionHandler:nil) }
                if let clip=object["walkClip"] as? String,["原地左转奔跑","螃蟹走路"].contains(clip),let data=try? JSONSerialization.data(withJSONObject:[clip]),let json=String(data:data,encoding:.utf8) { petView.evaluateJavaScript("DSHPet.setNextWalkAction(\(json)[0])",completionHandler:nil) }
                if let action=object["action"] as? String,action.count<100,let data=try? JSONSerialization.data(withJSONObject:["name":"builtinAction","action":action]),let json=String(data:data,encoding:.utf8) { petView.evaluateJavaScript("window.command(\(json))",completionHandler:nil) }
                if let kind=object["fireReminder"] as? String {
                    if kind == "focus" || kind == "focusBreak" { core.state.reminders.command(kind == "focus" ? "start" : "break");core.state.reminders.focusRemaining=0.1 }
                    else if kind == "rest" { core.state.settings.restEnabled=true;core.state.reminders.rest=core.state.settings.restMinutes*60 }
                    else if kind == "water" { core.state.settings.waterEnabled=true;core.state.reminders.water=core.state.settings.waterMinutes*60 }
                    lastTick=ProcessInfo.processInfo.systemUptime-1;tick()
                }
                if let scenario=object["scenario"] as? String { core.ephemeral.removeAll { $0.category == "whisper" };if scenario == "whisper" { core.addBubble(category:"whisper",title:"QWhaleMaiden",summary:"慢慢来，先做眼前这一步。",priority:10,lifetime:30) };tick() }
                if let focus=object["focus"] as? String,["start","pause","resume","cancel","break"].contains(focus) { settingsView?.evaluateJavaScript("document.querySelector('[data-focus=\"\(focus)\"]').click()",completionHandler:nil) }
                if let ui=object["petUI"] as? String {
                    let actions=["ackReminder":"document.querySelector('#ackReminder').click()","laterReminder":"document.querySelector('#later').click()","quiet":"document.querySelector('[data-control=quiet]').click()","bar":"showBar()","menuProbe":"showBar();document.querySelector('#pet').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true}));document.querySelector('#pet').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))","more":"showBar();if(document.querySelector('#morePanel').hidden)document.querySelector('#controlsButton').click()","interact":"document.querySelector('[data-more-tab=interact]').click()","tools":"document.querySelector('[data-more-tab=tools]').click()","manage":"document.querySelector('[data-more-tab=manage]').click()","focus":"document.querySelector('#focusToggle').click()","pause":"document.querySelector('#pauseQuick').click()","whisper":"document.querySelector('#saySomething').click()","escape":"document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))","idle":"transientUntil=0;forcedSleep=false;lastInteract=Date.now()-120000;state.activity='idle';updateMode()","feed":"document.querySelector('[data-pet=eat]').click()","through":"document.querySelector('[data-control=through]').click()","settingsRecover":"document.querySelector('#exitThrough').click()","widgets":"document.querySelector('#toggleWidgets').click()","focusSettings":"document.querySelector('#focusSettings').click()","calendar":"document.querySelector('#miniCalendar').click()","nextRandom":"(()=>{let v=document.querySelector('#art video.active');if(v&&Number.isFinite(v.duration))v.currentTime=v.duration-.03})()"]
                    if ui == "throwVertical" || ui == "throwDiagonal" || ui == "throwLeft" {
                        if let screen=motionScreen() { let b=motionBounds(screen),start=NSPoint(x:(b.minX+b.maxX)/2,y:(b.minY+b.maxY)/2);window.setFrameOrigin(start);runPet("command",["name":"nativeMotionStarted"]);motion.launch(position:start,velocity:NSPoint(x:ui == "throwVertical" ? 0 : ui == "throwLeft" ? -1800 : 1400,y:1100));inputBusy=true;resetMotionTelemetry();runtimeLog.record("test_throw",motionFields()) }
                    }
                    else if ui == "topEdge" || ui == "bottomEdge" {
                        stopNativeMotion("edge_test")
                        if let screen=motionScreen() { let b=motionBounds(screen);window.setFrameOrigin(NSPoint(x:(b.minX+b.maxX)/2,y:ui == "topEdge" ? b.maxY : b.minY));ensureVisible();publish() }
                    }
                    else if ui == "walkLeftEdge" || ui == "walkRightEdge" || ui == "walkMiddle" || ui == "runClipLeftEdge" || ui == "runClipRightEdge" {
                        stopNativeMotion("walk_test")
                        if let screen=motionScreen() { let b=motionBounds(screen);let x=["walkLeftEdge","runClipLeftEdge"].contains(ui) ? b.minX+20 : ["walkRightEdge","runClipRightEdge"].contains(ui) ? b.maxX-20 : (b.minX+b.maxX)/2;window.setFrameOrigin(NSPoint(x:x,y:b.minY));ensureVisible();if ui.hasPrefix("runClip") { runPet("command",["name":"builtinAction","action":"原地左转奔跑"]) } else { startWalk() } }
                    }
                    else if ui == "walkTurnLeft" || ui == "walkTurnRight" {
                        stopNativeMotion("walk_turn_test")
                        if let screen=motionScreen() { let b=motionBounds(screen),direction:Double=ui == "walkTurnLeft" ? -1 : 1;window.setFrameOrigin(NSPoint(x:direction<0 ? b.minX+180 : b.maxX-180,y:b.minY));ensureVisible();runPet("command",["name":"nativeMotionStarted"]);motion.walk(position:window.frame.origin,direction:direction);inputBusy=true;resetMotionTelemetry();runPet("command",["name":"nativeWalkDirection","direction":direction,"remaining":motion.walkRemaining]) }
                    }
                    else if ui == "motionStop" { stopNativeMotion("test_stop") }
                    else if ui == "widgetFixture" { smokeWidgetFixture=true;publish() }
                    else if ui == "clearWidgetFixture" { smokeWidgetFixture=false;publish() }
                    else if ui == "settingsRecover" { settingsView?.evaluateJavaScript("document.querySelector('#exitThrough').click()",completionHandler:nil) }
                    else if ui == "escapeGesture" { let base=ProcessInfo.processInfo.systemUptime;for i in 0..<3 { passThroughExit.receive(contacts:3,at:base+Double(i)*0.3);passThroughExit.receive(contacts:0,at:base+Double(i)*0.3+0.1) } }
                    else if ui == "leftEdge",let screen=window.screen ?? NSScreen.main { window.setFrameOrigin(NSPoint(x:screen.visibleFrame.minX-1,y:window.frame.minY));menusOnRight=false;ensureVisible();publish() }
                    else if ui == "rightEdge",let screen=window.screen ?? NSScreen.main { window.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-window.frame.width+1,y:window.frame.minY));menusOnRight=true;ensureVisible();publish() }
                    else if ui == "outsideClick" { dismissMenuIfOutside(NSPoint(x:window.frame.maxX+20,y:window.frame.maxY+20)) }
                    else if ui == "insideClick",let r=menuRegions.last { dismissMenuIfOutside(window.convertPoint(toScreen:NSPoint(x:r.midX,y:window.frame.height-r.midY))) }
                    else if let script=actions[ui] { petView.evaluateJavaScript(script,completionHandler:nil) }
                }
                if object["capture"] as? Bool == true { DispatchQueue.main.asyncAfter(deadline:.now()+(object["fast"] as? Bool == true ? 0.04 : 0.75)) { self.captureSmoke(captureID:captureID) } }
                return ["ok":true,"captureID":captureID]
            case "hook":
                guard let name = object["agent"] as? String, let agent = AgentID(rawValue:name), let raw = object["payload"] as? [String:Any] else { throw QWhaleMaidenError.message("无效 hook") }
                if var event = try AgentMapping.hook(agent:agent,raw:raw) {
                    if agent == .qwenwork,raw["hook_event_name"] as? String == "PostToolUse",let old=core.state.tasks[agent.rawValue+":"+event.sessionId],old.status == "waiting",let request=old.requestId,request == raw["tool_use_id"] as? String { event.type="attention.resolved";event.requestId=request }
                    let accepted = try core.accept(event); adapters.report[name] = "已收到 hook · 当前模式覆盖需验证"; tick(); return ["ok":true,"accepted":accepted] }
                return ["ok":true,"accepted":false,"reason":"ignored-hook"]
            case "event":
                guard let raw = object["payload"] as? [String:Any] else { throw QWhaleMaidenError.message("缺少事件") }
                var input=raw;input["source"]="self-report";if input["schemaVersion"] == nil { input["schemaVersion"]=1 }
                let event = try JSONDecoder().decode(AgentEvent.self,from:JSONSerialization.data(withJSONObject:input)); let accepted = try core.accept(event); tick(); return ["ok":true,"accepted":accepted]
            default: throw QWhaleMaidenError.message("未知命令")
            }
        } catch { return ["ok":false,"error":error.localizedDescription] }
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == Bundle.main.resourceURL!.standardizedFileURL, let body = message.body as? [String:Any], let type = body["type"] as? String else { return }
        let isPanel = message.webView === settingsView
        switch type {
        case "previewReminder": if isPanel,let kind=body["kind"] as? String { previewWellnessReminder(kind) }
        case "ready": runtimeLog.record("web_ready");publish()
        case "requestPetMenu": if !isPanel,!motion.active,ProcessInfo.processInfo.systemUptime>=menuBlockedUntil { runPet("command",["name":"revealPetMenu"]) }
        case "beginGrab": if !isPanel { beginGrab() }
        case "releaseGrab": if !isPanel { releaseGrab() }
        case "cancelGrab": if !isPanel {
            let reason=body["reason"] as? String ?? "context_menu"
            if motion.isGrabbing,NSEvent.pressedMouseButtons & 1 != 0,["pointer_cancel","blur"].contains(reason) { runtimeLog.record("pointer_capture_changed",["reason":reason]);if motion.phase == .drag { runPet("command",["name":"nativeDragStarted"]) } }
            else { stopNativeMotion(reason) }
        }
        case "stopMotion": if !isPanel { stopNativeMotion("web_action") }
        case "nativeWalk": if !isPanel { startWalk() }
        case "runAnimationDirection":
            if !isPanel,let token=body["token"] as? Int,let action=body["action"] as? String,["原地左转奔跑","原地漂浮踏步","螃蟹走路"].contains(action) {
                let direction=chooseRunDirection();runPet("resolveRunDirection",["token":token,"direction":direction]);runtimeLog.record("animation_direction",["action":action,"direction":direction])
            }
        case "runtimeDiagnostic": if !isPanel,let event=body["event"] as? String,["js_error","promise_error","video_error"].contains(event) { runtimeLog.record(event,level:"error",["message":String((body["message"] as? String ?? "").prefix(240))]) }

        case "menuRegions":
            guard !isPanel else { return };menuRegions=(body["rects"] as? [[String:Double]] ?? []).prefix(2).compactMap { r in guard let x=r["x"],let y=r["y"],let w=r["w"],let h=r["h"],[x,y,w,h].allSatisfy(\.isFinite),w>0,h>0 else { return nil };return NSRect(x:x,y:y,width:w,height:h) };watchMenuClicks()
        case "hitRegions":
            guard !isPanel else { return }; hitRegions = (body["rects"] as? [[String:Double]] ?? []).prefix(30).compactMap { r in guard let x=r["x"],let y=r["y"],let w=r["w"],let h=r["h"], [x,y,w,h].allSatisfy(\.isFinite) else { return nil }; return NSRect(x:x,y:y,width:w,height:h) }; updateHitTesting()
        case "busy": inputBusy = motion.active || (body["value"] as? Bool ?? false); updateHitTesting(); if !inputBusy { savePosition() }
        case "move":
            guard inputBusy, !isPanel, let dx=body["dx"] as? Double, let dy=body["dy"] as? Double, dx.isFinite, dy.isFinite, abs(dx)<500, abs(dy)<500 else { return }
            window.setFrameOrigin(NSPoint(x:window.frame.minX+dx,y:window.frame.minY-dy)); ensureVisible()
        case "bubbleLock": if body["locked"] as? Bool == true { selection.lockID = displayed?.id; pressed = displayed } else { selection.lockID = nil; if body["releasePress"] as? Bool == true { pressed = nil } }
        case "openBubble": if let id=body["id"] as? String { openBubble(id) }
        case "dismiss", "snooze":
            guard let id=body["id"] as? String, core.bubbles().contains(where: { $0.id == id }) else { return }
            if id.hasPrefix("preview-reminder:") { try? core.suppress(id);selection.lockID=nil;pressed=nil;tick();return }
            if type == "snooze",let bubble=core.ephemeral.first(where: { $0.id == id }),["rest","water"].contains(bubble.category) {
                if bubble.category == "rest" { core.state.reminders.restSnooze=600 } else { core.state.reminders.waterSnooze=600 }
                core.ephemeral.removeAll { $0.id == id };save();selection.lockID=nil;pressed=nil;tick();return
            }
            do { try core.suppress(id,until:type == "snooze" ? Date().timeIntervalSince1970+1800 : .greatestFiniteMagnitude) } catch { info=error.localizedDescription }; selection.lockID=nil; pressed=nil; tick()
        case "cycle": selection.lockID=nil; pressed=nil; displayed=selection.select(core.bubbles(),now:Date().timeIntervalSince1970,delta:(body["delta"] as? Int ?? 1)>0 ? 1 : -1); shownAt=Date().timeIntervalSince1970; publish()
        case "exitThrough": if isPanel { endThrough() }
        case "menuFocus": if !isPanel { let active=body["active"] as? Bool ?? false;window.acceptsMenuKeys=active;if active { window.makeKey() } else if window.isKeyWindow { window.resignKey() } }
        case "settings": openSettings();if let tab=body["tab"] as? String,["companion","agents","life","widgets","packs"].contains(tab) { pendingSettingsTab=tab;selectSettingsTab() }
        case "whisper": if !isPanel { emitWhisper();tick() }
        case "petSetting": if !isPanel,let key=body["key"] as? String,["walk","whispers","reducedMotion"].contains(key) { changeSetting(body) }
        case "control": if !isPanel { switch body["name"] as? String { case "quiet":toggleQuiet();case "corner":corner();case "hide":toggleHidden();case "through":toggleThrough();case "quit":quit();default:break } }
        case "controls": if !isPanel { statusItem.menu?.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil) }
        case "setting": if isPanel { changeSetting(body) }
        case "focus": if let name=body["name"] as? String { reminderCommand(name) }
        case "citySearch": if isPanel, let query=body["query"] as? String { weather.search(query) { [weak self] result in switch result { case .success(let cities):self?.cities=cities; case .failure(let error):self?.info=error.localizedDescription }; self?.publish() } }
        case "citySelect": if isPanel, let index=body["index"] as? Int, cities.indices.contains(index) { do { try weather.selectCity(cities[index],core:core); cities=[]; weather.refresh(core:core) { [weak self] in self?.publish() } } catch { info=error.localizedDescription }; publish() }
        case "weatherRefresh": weather.refresh(core:core,manual:true) { [weak self] in self?.publish() }
        case "calendarEnable": if isPanel { calendar.enable(core:core) { [weak self] in self?.publish() } }
        case "calendarSelect": if isPanel { core.state.settings.calendarIDs=(body["ids"] as? [String] ?? []).filter { id in calendar.calendars.contains { $0["id"] == id } }; save(); calendar.refresh(core:core); publish() }
        case "openCalendar": LaunchRouter.calendar()
        case "builtinAction": if isPanel, let action=body["action"] as? String, action.count<100 { core.state.settings.selectedPack=nil;refreshPacks();save();publish();if let data=try? JSONSerialization.data(withJSONObject:["name":"builtinAction","action":action]),let json=String(data:data,encoding:.utf8) { petView.evaluateJavaScript("window.command(\(json))",completionHandler:nil) } }
        case "importPack": if isPanel { importPack() }
        case "packSelect": if isPanel { core.state.settings.selectedPack=(body["id"] as? String).flatMap { id in packList.contains(where: { $0.id == id }) ? id : nil }; refreshPacks(); save(); publish() }
        case "login": if isPanel { do { if body["value"] as? Bool == true { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; info="登录项设置已提交，可在系统设置中查看" } catch { info=error.localizedDescription }; publish() }
        case "setupHook": if isPanel, let a=body["agent"] as? String, ["workbuddy","trae","dsh","qwenwork"].contains(a) { installHook(a) }
        case "clearTasks": if isPanel { let alert=NSAlert();alert.messageText="清除QWhaleMaiden保存的任务状态？";alert.informativeText="不会修改 Agent 的任务或对话。";alert.addButton(withTitle:"清除");alert.addButton(withTitle:"取消");if alert.runModal() == .alertFirstButtonReturn { core.state.tasks=[:]; core.state.suppressed=[:]; save(); tick() } }
        case "motionError": runtimeLog.record("asset_render_error",level:"error");info="素材无法渲染，已恢复默认形象"; core.state.settings.selectedPack=nil; currentPack=nil; save(); publish()
        default: break
        }
    }
    func changeSetting(_ body: [String:Any]) {
        guard let key=body["key"] as? String else { return }
        let flag=body["value"] as? Bool ?? false
        switch key {
        case "walk":core.state.settings.walk=flag
        case "whispers":core.state.settings.whispers=flag
        case "reducedMotion":core.state.settings.reducedMotion=flag
        case "reminderSound":core.state.settings.reminderSound=flag
        case "preview":core.state.settings.preview=flag
        case "restEnabled":core.state.settings.restEnabled=flag; core.state.reminders.rest=0;core.state.reminders.restSnooze=nil
        case "waterEnabled":core.state.settings.waterEnabled=flag; core.state.reminders.water=0;core.state.reminders.waterSnooze=nil
        case "calendarAlerts":core.state.settings.calendarAlerts=flag
        case "calendarEnabled": if !flag { core.state.settings.calendarEnabled=false; calendar.refresh(core:core) }
        case "restMinutes":if let v=body["value"] as? Double,v.isFinite { core.state.settings.restMinutes=max(5,min(180,v)); core.state.reminders.rest=0 }
        case "waterMinutes":if let v=body["value"] as? Double,v.isFinite { core.state.settings.waterMinutes=max(5,min(240,v)); core.state.reminders.water=0 }
        case "size":if let v=body["value"] as? Double,v.isFinite { let oldAnchor=petAnchor(core.state.settings.size,onRight:menusOnRight);core.state.settings.size=max(0.65,min(1.5,v)); let f=window.frame;let anchor=f.minX+oldAnchor;let dim=petPanelSize(core.state.settings.size);window.setContentSize(dim);window.setFrameOrigin(NSPoint(x:anchor-petAnchor(core.state.settings.size,onRight:menusOnRight),y:f.minY));ensureVisible() }
        case "agent":if let name=body["agent"] as? String, let a=AgentID(rawValue:name) { core.state.settings.disabledAgents.removeAll { $0 == a }; if !flag { core.state.settings.disabledAgents.append(a) };adapters.resetBaseline(a) }
        default:return
        }
        save(); publish()
    }
    func importPack() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=true; panel.allowsMultipleSelection=false; panel.message="选择素材包文件夹或 ZIP（根目录含 manifest.json）"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let installed=try packs.install(url); refreshPacks(); info="已导入："+installed.manifest.name+"，可预览后切换" } catch { info="导入失败："+error.localizedDescription }; publish()
    }
    func installHook(_ agent: String) {
        let cli=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/starbud-event")
        let process=Process(); process.executableURL=cli; process.arguments=["setup","--agent",agent,"--apply"]
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); info=process.terminationStatus == 0 ? "接入已安装并保留原配置；宿主如未加载，请在空闲时重启后验证" : "安装失败；请运行 CLI dry-run 检查";if let id=AgentID(rawValue:agent),[.dsh,.qwenwork].contains(id) { adapters.report[agent]=BridgeSetup.status(agent:id,home:adapters.home) } } catch { info=error.localizedDescription }; publish()
    }
    func selectSettingsTab() {
        guard let tab=pendingSettingsTab else { return }
        settingsView?.evaluateJavaScript("(()=>{let b=document.querySelector('[data-tab=\"\(tab)\"]');if(!b)return false;b.click();return true})()") { [weak self] value,_ in if value as? Bool == true { self?.pendingSettingsTab=nil } }
    }
    func emitWhisper() { core.ephemeral.removeAll { $0.category == "whisper" };core.addBubble(category:"whisper",title:"QWhaleMaiden",summary:chatter.next("idle"),priority:10,lifetime:8);runPet("command",["name":"speak"]) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { runtimeLog.record("web_process_terminated",level:"error");stopNativeMotion("web_process_terminated");webView.reload() }
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { runtimeLog.record("web_navigation_error",level:"error",["message":String(error.localizedDescription.prefix(200))]) }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { publish();if webView === settingsView { selectSettingsTab() } }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        guard let url=action.request.url else { decisionHandler(.cancel);return }
        decisionHandler(url.isFileURL && url.standardizedFileURL.path.hasPrefix(Bundle.main.resourceURL!.path+"/") ? .allow : .cancel)
    }
    func scheduleSmoke() {
        guard let root=smokeDirectory else { return }; try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
            guard let self=self else { return }
            self.petView.evaluateJavaScript("JSON.stringify(window.petDiagnostics())") { result,error in
                let report:[String:Any] = ["view":result ?? "missing","error":error?.localizedDescription ?? "","version":"0.1.2"]
                if let data=try? JSONSerialization.data(withJSONObject:report,options:.prettyPrinted) { try? data.write(to:root.appendingPathComponent("webview.json")) }
            }
            self.petView.takeSnapshot(with:nil) { image,error in
                if let image=image,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:root.appendingPathComponent("pet.png")) }
            }
            self.openSettings()
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { self.settingsView?.takeSnapshot(with:nil) { image,_ in
                if let image=image,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:root.appendingPathComponent("settings.png")) }
            } }
        }
    }
    func captureSmoke(captureID:String) {
        guard let root=smokeDirectory else { return }
        petView.takeSnapshot(with:nil) { image,error in
            if let image=image,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:root.appendingPathComponent("pet-current.png")) }
        }
        settingsView?.takeSnapshot(with:nil) { image,error in
            if let image=image,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) { try? png.write(to:root.appendingPathComponent("panel-current.png")) }
        }
        settingsView?.evaluateJavaScript("JSON.stringify({tab:document.querySelector('[data-tab].active')?.dataset.tab})") { result,_ in
            if let text=result as? String { try? text.write(to:root.appendingPathComponent("settings-view.json"),atomically:true,encoding:.utf8) }
        }
        petView.evaluateJavaScript("JSON.stringify({mode:document.body.dataset.mode,bubble:!document.querySelector('#notice').hidden,source:document.querySelector('#noticeSource').textContent,text:document.querySelector('#noticeText').textContent,regions:!!document.querySelector('#pet'),pet:window.petDiagnostics(),ui:window.uiDiagnostics()})") { result,error in
            if let text=result as? String,let data=text.data(using:.utf8),var object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { object["captureID"]=captureID;if let encoded=try? JSONSerialization.data(withJSONObject:object) { try? encoded.write(to:root.appendingPathComponent("current-view.json"),options:.atomic) } }
        }
    }
}
