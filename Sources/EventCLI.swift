import Foundation
import Darwin

@main struct EventCLI {
    static func main() {
        do { try run() }
        catch {
            let object: [String:Any] = ["ok":false,"error":error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject:object) { FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8)) }
            // Hook telemetry failure must not alter the source Agent's decision.
            exit(CommandLine.arguments.contains("hook") ? 0 : 1)
        }
    }
    static func emit(_ object: [String:Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func value(_ name: String) -> String? { guard let i = args.firstIndex(of:name), i+1 < args.count else { return nil }; return args[i+1] }
        let root = URL(fileURLWithPath:value("--data-dir") ?? ProcessInfo.processInfo.environment["STARBUD_DATA_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QWhaleMaiden/v1").path)
        let command = args.first ?? "help"
        if command == "setup" { try setup(agent:value("--agent"), apply:args.contains("--apply"), home:value("--home"),remove:args.contains("--remove")); return }
        if command == "help" || command == "--help" {
            print("starbud-event status | show | quit | hook --agent workbuddy|trae|dsh|qwenwork | event | setup --agent workbuddy|trae|dsh|qwenwork [--apply] [--remove] [--home PATH]\nUse --data-dir PATH or STARBUD_DATA_DIR for isolated testing. hook/event read JSON on stdin.")
            return
        }
        var object: [String:Any]
        switch command {
        case "status": object = ["command":"status"]
        case "show": object = ["command":"show"]
        case "preview-reminder": object = ["command":"previewReminder","kind":value("--kind") ?? "focus"]
        case "quit": object = ["command":"quit"]
        case "verify": object = ["command":"verifyView","capture":true,"captureID":UUID().uuidString,"fast":args.contains("--fast")];if let tab=value("--tab") { object["tab"]=tab };if let toggle=value("--toggle") { object["toggle"]=toggle };if let action=value("--action") { object["action"]=action };if let scenario=value("--scenario") { object["scenario"]=scenario };if let focus=value("--focus") { object["focus"]=focus };if let ui=value("--pet-ui") { object["petUI"]=ui };if let clip=value("--walk-clip") { object["walkClip"]=clip };if let kind=value("--fire-reminder") { object["fireReminder"]=kind }
        case "hook", "event":
            var data = Data()
            while true {
                let chunk = FileHandle.standardInput.readData(ofLength:16*1024); if chunk.isEmpty { break }; data.append(chunk)
                guard data.count <= 256*1024 else { throw QWhaleMaidenError.message("输入超过大小上限") }
            }
            guard let raw = jsonObject(data) else { throw QWhaleMaidenError.message("输入必须为 JSON 对象") }
            if command == "hook" {
                guard let agent = value("--agent"), AgentID(rawValue:agent) != nil else { throw QWhaleMaidenError.message("请指定 agent") }
                object = ["command":"hook","agent":agent,"payload":raw]
            } else { object = ["command":"event","payload":raw] }
        default: throw QWhaleMaidenError.message("未知命令")
        }
        let result = try LocalChannel.request(path:LocalChannel.path(dataRoot:root),object:object)
        if !args.contains("--silent") { try emit(result) }
        if result["ok"] as? Bool != true { throw QWhaleMaidenError.message(result["error"] as? String ?? "报告失败") }
    }
    static func setup(agent: String?, apply: Bool, home: String?, remove: Bool = false) throws {
        guard let name=agent,let id=AgentID(rawValue:name) else { throw QWhaleMaidenError.message("请指定受支持的来源") }
        if [.dsh,.qwenwork].contains(id) {
            try emit(BridgeSetup.setup(agent:id,home:URL(fileURLWithPath:home ?? FileManager.default.homeDirectoryForCurrentUser.path),helper:URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL,apply:apply,remove:remove));return
        }
        guard [.workbuddy,.trae].contains(id) else { throw QWhaleMaidenError.message("Codex/灵犀走只读日志") }
        let base = URL(fileURLWithPath:home ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let config = base.appendingPathComponent(id == .workbuddy ? ".workbuddy/settings.json" : ".trae-cn/hooks.json")
        let fm = FileManager.default
        let original = fm.fileExists(atPath:config.path) ? try Data(contentsOf:config) : Data("{}".utf8)
        guard var document = jsonObject(original) else { throw QWhaleMaidenError.message("现有配置不是有效 JSON；未改动") }
        let executable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        let command = quote(executable) + " hook --agent " + id.rawValue
        let events = id == .workbuddy ? ["UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop"] : ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","Notification"]
        var hooks = document["hooks"] as? [String:Any] ?? [:]
        if document["hooks"] != nil && !(document["hooks"] is [String:Any]) { throw QWhaleMaidenError.message("hooks 格式不兼容；未改动") }
        var additions: [String] = []
        for event in events {
            let existing = hooks[event] as? [[String:Any]] ?? []
            if hooks[event] != nil && !(hooks[event] is [[String:Any]]) { throw QWhaleMaidenError.message("hook 条目格式不兼容；未改动") }
            if remove {
                var removed=false
                let retained=existing.compactMap { row -> [String:Any]? in
                    guard let entries=row["hooks"] as? [[String:Any]] else { return row }
                    let rest=entries.filter { $0["command"] as? String != command }
                    if rest.count == entries.count { return row }
                    removed=true;if rest.isEmpty { return nil }
                    var updated=row;updated["hooks"]=rest;return updated
                }
                if removed { hooks[event]=retained;additions.append(event) };continue
            }
            if existing.contains(where: { row in (row["hooks"] as? [[String:Any]] ?? []).contains { $0["command"] as? String == command } }) { continue }
            hooks[event] = existing + [["matcher":"*","hooks":[["type":"command","command":command,"timeout":2]]]]
            additions.append(event)
        }
        try emit(["ok":true,"mode":apply ? "apply" : "dry-run","path":config.path,"changes":additions,"remove":remove,"existingHooksPreserved":true,"command":command])
        guard apply && !additions.isEmpty else { return }
        document["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
        _ = try JSONSerialization.jsonObject(with:output)
        if fm.fileExists(atPath:config.path), try Data(contentsOf:config) != original { throw QWhaleMaidenError.message("配置在读取后变化，未写入；请重试") }
        try fm.createDirectory(at:config.deletingLastPathComponent(),withIntermediateDirectories:true)
        let backup = config.appendingPathExtension("starbud-backup-"+UUID().uuidString)
        try original.write(to:backup,options:.atomic); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
        try output.write(to:config,options:.atomic); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:config.path)
        try emit(["ok":true,"installed":true,"backup":backup.path,"restartAgentRequired":true])
    }
}
