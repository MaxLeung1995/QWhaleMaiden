import Foundation

enum BridgeSetup {
    static let pluginName = "starbud-bridge"
    static func directory(agent:AgentID,home:URL) -> URL {
        home.appendingPathComponent(agent == .dsh ? ".dsh/profiles/desktop/starbud-bridge" : ".qwenworkcn/plugins-custom/starbud-bridge")
    }
    static func status(agent:AgentID,home:URL) -> String {
        let dir=directory(agent:agent,home:home)
        guard FileManager.default.fileExists(atPath:dir.appendingPathComponent(".starbud-owned").path) else { return "需要安装接入插件" }
        return "接入插件已安装 · 等待宿主事件验证"
    }
    static func setup(agent:AgentID,home:URL,helper:URL,apply:Bool,remove:Bool) throws -> [String:Any] {
        let fm=FileManager.default,dir=directory(agent:agent,home:home),marker=dir.appendingPathComponent(".starbud-owned")
        if fm.fileExists(atPath:dir.path),!fm.fileExists(atPath:marker.path) { throw QWhaleMaidenError.message("同名目录不属于QWhaleMaiden，未修改") }
        let patch=home.appendingPathComponent(".dsh/profiles/desktop/cordis.patch.yml")
        let old=agent == .dsh && fm.fileExists(atPath:patch.path) ? try Data(contentsOf:patch) : Data()
        let start="# BEGIN STARBUD BRIDGE\n",end="# END STARBUD BRIDGE\n"
        var patchText=String(decoding:old,as:UTF8.self)
        if agent == .dsh,let a=patchText.range(of:start) {
            guard let b=patchText.range(of:end,range:a.upperBound..<patchText.endIndex) else { throw QWhaleMaidenError.message("DSH QWhaleMaiden配置区块不完整，未修改") }
            patchText.removeSubrange(a.lowerBound..<b.upperBound)
        }
        func literal(_ text:String) -> String { String(data:try! JSONSerialization.data(withJSONObject:[text]),encoding:.utf8)!.dropFirst().dropLast().description }
        if agent == .dsh && !remove {
            patchText += (patchText.hasSuffix("\n") || patchText.isEmpty ? "" : "\n") + start
            patchText += "- insert:\n    - id: starbud-bridge\n      name: " + literal(dir.appendingPathComponent("index.mjs").path) + "\n      config:\n        helperPath: " + literal(helper.path) + "\n" + end
        }
        var result:[String:Any] = ["ok":true,"mode":apply ? "apply":"dry-run","agent":agent.rawValue,"path":dir.path,"remove":remove,"hostRestartMayBeRequired":true,"existingConfigurationPreserved":true]
        if agent == .dsh { result["configPath"]=patch.path }
        guard apply else { return result }
        // Resolve before any mutation so a missing bundled resource cannot leave a partial install.
        let resource=helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/bridges/dsh/index.mjs")
        let module = agent == .dsh && !remove ? try Data(contentsOf:resource) : Data()
        if agent == .dsh {
            if fm.fileExists(atPath:patch.path),try Data(contentsOf:patch) != old { throw QWhaleMaidenError.message("DSH 配置已变化，未修改") }
            if !old.isEmpty {
                let backup=patch.appendingPathExtension("starbud-backup-"+UUID().uuidString)
                try old.write(to:backup,options:.atomic);result["backup"]=backup.path
            }
        }
        if remove {
            if fm.fileExists(atPath:marker.path) { try fm.removeItem(at:dir) }
        } else {
            try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try Data("starbud-bridge-v1\n".utf8).write(to:marker,options:.atomic)
            if agent == .dsh { try module.write(to:dir.appendingPathComponent("index.mjs"),options:.atomic) }
            else {
                let manifest:[String:Any] = ["name":pluginName,"version":"1.0.0","description":"QWhaleMaiden本机任务状态通知；仅转发技术元数据"]
                let metadata=dir.appendingPathComponent(".qoder-plugin")
                try fm.createDirectory(at:metadata,withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:metadata.appendingPathComponent("plugin.json"),options:.atomic)
                let quote="'"+helper.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
                let command=quote+" hook --agent qwenwork --silent"
                let events=["UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest","Notification","Stop"]
                let hooks=Dictionary(uniqueKeysWithValues:events.map { ($0,[["matcher":"*","hooks":[["type":"command","command":command,"timeout":2]]]]) })
                try JSONSerialization.data(withJSONObject:["hooks":hooks],options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("hooks.json"),options:.atomic)
            }
        }
        if agent == .dsh {
            try fm.createDirectory(at:patch.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(patchText.utf8).write(to:patch,options:.atomic)
        }
        return result
    }
}
