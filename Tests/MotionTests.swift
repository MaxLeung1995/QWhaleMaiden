import Foundation
@main struct MotionTests {
 static func main() throws {
    var count=0
    func check(_ ok: Bool,_ name: String) { precondition(ok,name);count+=1;print("PASS: \(name)") }
    let bounds=MotionBounds(minX:-270,maxX:1050,minY:-42,maxY:1100)
    var m=PetMotion();m.launch(position:NSPoint(x:300,y:100),velocity:NSPoint(x:0,y:1100))
    var sawApex=false
    for _ in 0..<120 { _=m.advance(seconds:1.0/120,bounds:bounds);if abs(m.velocity.y)<15 { sawApex=true;check(m.phase == .flight && m.position.y>bounds.minY+200,"vertical throw remains airborne at apex") } }
    check(sawApex,"vertical apex regression exercised")
    for _ in 0..<2000 where m.active { _=m.advance(seconds:1.0/120,bounds:bounds) }
    check(!m.active && m.position.y==bounds.minY,"vertical throw settles only on floor")
    for vx in [-2400.0,2400.0] {
        m.launch(position:NSPoint(x:300,y:300),velocity:NSPoint(x:vx,y:900));var edges=Set<String>()
        for _ in 0..<2400 where m.active { edges.formUnion(m.advance(seconds:1.0/120,bounds:bounds));precondition(m.position.x>=bounds.minX&&m.position.x<=bounds.maxX&&m.position.y>=bounds.minY&&m.position.y<=bounds.maxY) }
        check(!m.active && edges.contains(vx<0 ? "left":"right"),"fast throw reaches body collision boundary and settles")
    }
    m.grab(position:NSPoint(x:100,y:100),cursor:NSPoint(x:150,y:150),now:0)
    _=m.follow(cursor:NSPoint(x:300,y:200),now:0.05,bounds:bounds)
    check(m.position==NSPoint(x:250,y:150),"native drag follows cursor directly without spring backlog")
    m.translate(x:100);_=m.follow(cursor:NSPoint(x:310,y:200),now:0.06,bounds:bounds)
    check(m.position.x==360 && m.grabOffset.x==50,"menu side change preserves drag cursor offset")
    _=m.release(now:0.065,throwsEnabled:true);check(m.phase == .flight,"recent fast drag launches inertia")
    m.grab(position:NSPoint(x:100,y:100),cursor:NSPoint(x:100,y:100),now:0)
    for i in 1...40 { _=m.follow(cursor:NSPoint(x:300,y:300),now:Double(i)/60,bounds:bounds) }
    _=m.release(now:0.67,throwsEnabled:true);check(m.phase == .idle,"held stationary drag does not fling from stale velocity")
    m.launch(position:NSPoint(x:100,y:300),velocity:NSPoint(x:Double.nan,y:1));let invalid=m.advance(seconds:0.02,bounds:bounds)
    check(!m.active && invalid.contains("invalid_motion"),"invalid coordinates stop instead of hanging timer")
    var landings:[NSPoint]=[]
    for hz in [30.0,60.0,120.0] { m.launch(position:NSPoint(x:300,y:400),velocity:NSPoint(x:900,y:700));for _ in 0..<Int(hz*20) where m.active { _=m.advance(seconds:1/hz,bounds:bounds) };check(!m.active && m.position.y==bounds.minY,"throw settles at \(Int(hz)) Hz");landings.append(m.position) }
    check(abs(landings[0].x-landings[2].x)<8,"landing is stable across display frame rates")
    check(PetMotion.walkDirection(position:NSPoint(x:bounds.minX,y:0),bounds:bounds,randomDirection:-1)==1,"left edge always chooses right")
    check(PetMotion.walkDirection(position:NSPoint(x:bounds.minX+140,y:0),bounds:bounds,randomDirection:-1)==1,"near left threshold overrides outward random choice")
    check(PetMotion.walkDirection(position:NSPoint(x:bounds.maxX-140,y:0),bounds:bounds,randomDirection:1)==(-1),"near right threshold overrides outward random choice")
    check(PetMotion.walkDirection(position:NSPoint(x:bounds.maxX,y:0),bounds:bounds,randomDirection:1)==(-1),"right edge always chooses left")
    let middle=NSPoint(x:(bounds.minX+bounds.maxX)/2,y:0)
    for direction in [-1.0,1.0] { check(PetMotion.walkDirection(position:middle,bounds:bounds,randomDirection:direction)==direction,"middle preserves random direction \(direction)") }
    m.walk(position:NSPoint(x:bounds.minX+141,y:0),direction:-1)
    let leftTurn=m.advance(seconds:0.05,bounds:bounds)
    check(m.velocity.x>0 && leftTurn.contains("turn_right") && m.position.x>bounds.minX+139,"running near left edge turns before impact")
    m.walk(position:NSPoint(x:bounds.maxX-141,y:0),direction:1)
    let rightTurn=m.advance(seconds:0.05,bounds:bounds)
    check(m.velocity.x<0 && rightTurn.contains("turn_left") && m.position.x<bounds.maxX-139,"running near right edge turns before impact")
    let narrow=MotionBounds(minX:0,maxX:180,minY:0,maxY:200)
    m.walk(position:NSPoint(x:90,y:0),direction:-1);var turns=0
    for _ in 0..<170 { turns+=m.advance(seconds:1.0/60,bounds:narrow).filter { $0.hasPrefix("turn_") }.count }
    check(turns<=3,"narrow desktop does not oscillate every frame")
    for screen in [NSRect(x:0,y:25,width:1440,height:850),NSRect(x:-1920,y:-300,width:1920,height:1080),NSRect(x:1440,y:900,width:2560,height:1440)] {
        let body=NSRect(x:200,y:270,width:111.158,height:131.984),height=721.984
        let b=MotionBounds.forScreen(screen,body:body,windowHeight:height)
        check(abs(b.minX+body.minX-screen.minX)<0.001 && abs(b.maxX+body.maxX-screen.maxX)<0.001,"display body boundaries use live horizontal frame")
        check(abs(b.minY+height-body.maxY-screen.minY)<0.001 && abs(b.maxY+height-body.minY-screen.maxY)<0.001,"display body boundaries use live vertical frame")
    }
    let displays=[NSRect(x:0,y:0,width:1440,height:900),NSRect(x:-1920,y:0,width:1920,height:1080)]
    check(MotionBounds.screenIndex(frames:displays,body:NSRect(x:-800,y:300,width:112,height:132))==1,"external display selected by pet body instead of transparent canvas")
    check(MotionBounds.screenIndex(frames:displays,body:NSRect(x:200,y:300,width:112,height:132),cursor:NSPoint(x:-1000,y:400))==1,"drag crosses to cursor display")
    check(MotionBounds.screenIndex(frames:[displays[0]],body:NSRect(x:-1000,y:300,width:112,height:132))==0,"unplugged display recovers nearest remaining display")
    let tiny=MotionBounds.forScreen(NSRect(x:0,y:0,width:80,height:80),body:NSRect(x:200,y:200,width:112,height:132),windowHeight:700)
    check(tiny.minX<=tiny.maxX && tiny.minY<=tiny.maxY,"oversized pet on tiny display keeps valid collision bounds")
    let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("starbud-log-test-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let log=RuntimeLog(directory:root,limit:1024,retained:3)
    for i in 0..<100 { log.record("test_event",["index":i,"screen":[CGFloat(1),CGFloat(2)]]) };log.flush()
    let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
    check(files.count==4,"runtime log rotates and retains only three backups")
    var total=0
    for file in files { let bytes=try Data(contentsOf:file);total+=bytes.count;for row in String(decoding:bytes,as:UTF8.self).split(separator:"\n") { let object=try JSONSerialization.jsonObject(with:Data(row.utf8)) as! [String:Any];precondition(object["timestamp"] != nil && object["event"] as? String == "test_event");precondition((object["fields"] as? [String:Any])?["screen"] as? [Double] == [1,2]) } }
    check(total<=4096,"rotated logs stay within configured size")
    print("\(count) motion and log checks passed")
 }
}
