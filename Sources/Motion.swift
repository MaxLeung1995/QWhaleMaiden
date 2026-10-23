import AppKit

struct MotionBounds {
    var minX: Double; var maxX: Double; var minY: Double; var maxY: Double
    static func forScreen(_ frame: NSRect, body: NSRect, windowHeight: Double) -> MotionBounds {
        let minX=frame.minX-body.minX,minY=frame.minY-(windowHeight-body.maxY)
        return MotionBounds(minX:minX,maxX:max(minX,frame.maxX-body.maxX),minY:minY,maxY:max(minY,frame.maxY-(windowHeight-body.minY)))
    }
    static func screenIndex(frames: [NSRect], body: NSRect, cursor: NSPoint? = nil) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let cursor=cursor,let index=frames.firstIndex(where: { $0.contains(cursor) }) { return index }
        // Largest visible body overlap, then the nearest screen after a display is unplugged.
        let center=NSPoint(x:body.midX,y:body.midY)
        func score(_ frame:NSRect) -> (Double,Double) {
            let intersection=frame.intersection(body)
            let area=intersection.isNull ? 0 : intersection.width*intersection.height
            let x=max(frame.minX,min(center.x,frame.maxX)),y=max(frame.minY,min(center.y,frame.maxY))
            return (area,-hypot(center.x-x,center.y-y))
        }
        return frames.indices.max { let a=score(frames[$0]),b=score(frames[$1]);return a.0 == b.0 ? a.1<b.1 : a.0<b.0 }
    }
    func clamp(_ point: NSPoint) -> NSPoint { NSPoint(x:max(minX,min(point.x,maxX)),y:max(minY,min(point.y,maxY))) }
}

struct PetMotion {
    enum Phase: String { case idle, pressed, drag, flight, walk }
    var phase: Phase = .idle
    var position = NSPoint.zero
    var velocity = NSPoint.zero
    var grabOffset = NSPoint.zero
    var grabStart = NSPoint.zero
    var samples: [(NSPoint, Double)] = []
    var accumulator: Double = 0
    var age: Double = 0
    var walkRemaining: Double = 0
    var isGrabbing: Bool { phase == .pressed || phase == .drag }
    var active: Bool { phase != .idle }
    mutating func stop() { phase = .idle; velocity = .zero; samples=[]; age=0;accumulator=0 }
    mutating func grab(position: NSPoint, cursor: NSPoint, now: Double) {
        stop();self.position=position;grabOffset=NSPoint(x:position.x-cursor.x,y:position.y-cursor.y);grabStart=cursor;samples=[(cursor,now)];phase = .pressed
    }
    mutating func follow(cursor: NSPoint, now: Double, bounds: MotionBounds) -> Bool {
        let began=phase == .pressed && hypot(cursor.x-grabStart.x,cursor.y-grabStart.y)>6
        if began { phase = .drag }
        samples.append((cursor,now));samples.removeAll { now-$0.1>0.12 }
        if phase == .drag { position=bounds.clamp(NSPoint(x:cursor.x+grabOffset.x,y:cursor.y+grabOffset.y)) }
        return began
    }
    mutating func release(now: Double, throwsEnabled: Bool) -> Bool {
        let dragged=phase == .drag
        guard isGrabbing else { return false }
        velocity = .zero
        if dragged,throwsEnabled,let first=samples.first,let last=samples.last,last.1-first.1>=0.025,now-last.1<0.15 {
            let span=last.1-first.1,vx=(last.0.x-first.0.x)/span,vy=(last.0.y-first.0.y)/span,speed=hypot(vx,vy)
            if speed>500 { let gain=min(1,2400/speed);velocity=NSPoint(x:vx*gain,y:vy*gain) }
        }
        phase = hypot(velocity.x,velocity.y)>0 ? .flight : .idle;age=0;samples=[]
        return dragged
    }
    mutating func launch(position: NSPoint, velocity: NSPoint) { stop();self.position=position;self.velocity=velocity;phase = .flight }
    static func turnDistance(bounds: MotionBounds, requested: Double=140) -> Double { min(requested,max(0,(bounds.maxX-bounds.minX)/3)) }
    static func walkDirection(position: NSPoint,bounds: MotionBounds,randomDirection: Double,nearDistance: Double=140) -> Double {
        let margin=turnDistance(bounds:bounds,requested:nearDistance)
        if position.x-bounds.minX<=margin { return 1 }
        if bounds.maxX-position.x<=margin { return -1 }
        return randomDirection<0 ? -1 : 1
    }
    mutating func walk(position: NSPoint, direction: Double) { stop();self.position=position;velocity=NSPoint(x:direction*45,y:0);walkRemaining=3;phase = .walk }
    mutating func translate(x: Double) { position.x+=x;grabOffset.x+=x }
    // Native coordinates point up. Substeps make collision/settling independent of display refresh rate.
    mutating func advance(seconds: Double, bounds: MotionBounds) -> [String] {
        guard phase == .flight || phase == .walk else { return [] }
        guard seconds.isFinite,[position.x,position.y,velocity.x,velocity.y,bounds.minX,bounds.maxX,bounds.minY,bounds.maxY].allSatisfy(\.isFinite),bounds.minX<=bounds.maxX,bounds.minY<=bounds.maxY else { stop();return ["invalid_motion"] }
        accumulator+=max(0,min(0.15,seconds));var collisions=Set<String>()
        while accumulator+1e-10>=1.0/120 && active {
            let dt=1.0/120;accumulator=max(0,accumulator-dt);age+=dt
            if phase == .walk {
                walkRemaining-=dt;if walkRemaining<=0 { stop();break }
                let margin=Self.turnDistance(bounds:bounds)
                if velocity.x<0 && position.x-bounds.minX<=margin { velocity.x=abs(velocity.x);collisions.insert("turn_right") }
                else if velocity.x>0 && bounds.maxX-position.x<=margin { velocity.x = -abs(velocity.x);collisions.insert("turn_left") }
            }
            else { velocity.y-=1600*dt;velocity.x*=exp(-0.25*dt) }
            position.x+=velocity.x*dt;position.y+=velocity.y*dt
            if position.x<bounds.minX { position.x=bounds.minX;velocity.x=abs(velocity.x)*(phase == .walk ? 1 : 0.72);collisions.insert("left") }
            if position.x>bounds.maxX { position.x=bounds.maxX;velocity.x = -abs(velocity.x)*(phase == .walk ? 1 : 0.72);collisions.insert("right") }
            if phase == .flight {
                if position.y>bounds.maxY { position.y=bounds.maxY;velocity.y = -abs(velocity.y)*0.6;collisions.insert("top") }
                if position.y<=bounds.minY {
                    position.y=bounds.minY
                    let impact=abs(velocity.y);velocity.y=impact<85 ? 0 : impact*0.58
                    velocity.x*=exp(-9*dt)
                    if impact>=85 { collisions.insert("bottom") }
                    if abs(velocity.x)<12 && velocity.y==0 { stop();collisions.insert("settled") }
                }
                // Safety limit always finishes on the floor, never at the apex.
                if age>=15 { position.y=bounds.minY;stop();collisions.insert("timeout_settled") }
            }
        }
        return collisions.sorted()
    }
}
