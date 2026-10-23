import AppKit
import Carbon
import Darwin

// ABI checked against asmagill/hs._asm.undocumented.touchdevice/MultitouchSupport.h.
// Uses the built-in private framework only while pass-through is enabled. No coordinates are read.
private typealias TouchFrame = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt, Double, UInt, UnsafeMutableRawPointer?) -> Void
private let touchFrame: TouchFrame = { _,_,count,time,_,context in
    guard let context=context else { return }
    let owner=Unmanaged<PassThroughExit>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak owner] in owner?.receive(contacts:Int(min(count,100)),at:time) }
}
private let restoreHotKey: EventHandlerUPP = { _,_,context in
    guard let context=context else { return OSStatus(eventNotHandledErr) }
    let owner=Unmanaged<PassThroughExit>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { [weak owner] in owner?.restore() }
    return noErr
}

final class PassThroughExit {
    private typealias CreateDevice = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias RegisterFrame = @convention(c) (UnsafeMutableRawPointer?,TouchFrame,UnsafeMutableRawPointer?) -> Bool
    private typealias UnregisterFrame = @convention(c) (UnsafeMutableRawPointer?,TouchFrame) -> Bool
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer?,Int32) -> Int32
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias ReleaseDevice = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private var library: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregister: UnregisterFrame?
    private var stopDevice: StopDevice?
    private var releaseDevice: ReleaseDevice?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var recognizer=TripleThreeTapRecognizer()
    private var onExit: (() -> Void)?
    private(set) var enabled=false
    private(set) var gestureConnected=false
    private(set) var hotkeyRegistered=false
    var status: [String:Any] { ["enabled":enabled,"gestureConnected":gestureConnected,"hotkeyRegistered":hotkeyRegistered,"shortcut":"Control+Option+Command+P"] }

    func begin(onExit: @escaping () -> Void) -> Bool {
        stop();self.onExit=onExit;enabled=true
        var event=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let context=Unmanaged.passUnretained(self).toOpaque()
        if InstallEventHandler(GetApplicationEventTarget(),restoreHotKey,1,&event,context,&handler) == noErr {
            hotkeyRegistered=RegisterEventHotKey(UInt32(kVK_ANSI_P),UInt32(controlKey|optionKey|cmdKey),EventHotKeyID(signature:0x53425544,id:1),GetApplicationEventTarget(),0,&hotkey) == noErr
        }
        connectTrackpad(context:context)
        // A guaranteed public hotkey is required even if the private trackpad API is unavailable.
        guard hotkeyRegistered else { stop();return false }
        return true
    }
    private func symbol<T>(_ name:String,as type:T.Type) -> T? {
        guard let library=library,let address=dlsym(library,name) else { return nil }
        return unsafeBitCast(address,to:type)
    }
    private func connectTrackpad(context: UnsafeMutableRawPointer) {
        if library == nil { library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_NOW|RTLD_LOCAL) }
        guard let create=symbol("MTDeviceCreateDefault",as:CreateDevice.self),let register=symbol("MTRegisterContactFrameCallbackWithRefcon",as:RegisterFrame.self),let begin=symbol("MTDeviceStart",as:StartDevice.self),let unreg=symbol("MTUnregisterContactFrameCallback",as:UnregisterFrame.self),let end=symbol("MTDeviceStop",as:StopDevice.self),let release=symbol("MTDeviceRelease",as:ReleaseDevice.self),let current=create() else { return }
        device=current;unregister=unreg;stopDevice=end;releaseDevice=release
        if register(current,touchFrame,context),begin(current,0x10000000) == noErr { gestureConnected=true }
        else { _=unreg(current,touchFrame);_=end(current);release(current);device=nil }
    }
    func receive(contacts:Int,at time:Double) {
        guard enabled else { return }
        if recognizer.feed(contacts:contacts,at:time) { restore() }
    }
    func restore() { guard enabled else { return };let action=onExit;stop();action?() }
    func stop() {
        enabled=false;recognizer.reset();onExit=nil
        if let hotkey=hotkey { UnregisterEventHotKey(hotkey);self.hotkey=nil }
        if let handler=handler { RemoveEventHandler(handler);self.handler=nil }
        if let device=device { _=unregister?(device,touchFrame);_=stopDevice?(device);releaseDevice?(device);self.device=nil }
        hotkeyRegistered=false;gestureConnected=false
        // Keep the framework loaded: queued system callbacks may still be returning.
    }
    deinit { stop() }
}
