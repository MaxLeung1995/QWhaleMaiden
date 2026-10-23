import Foundation

enum AgentMapping {
    static func timestamp(_ value: Any?) -> Double? {
        if let n=value as? NSNumber { let t=n.doubleValue;return t>1e12 ? t/1000 : t }
        if let s=value as? String {
            if let n=Double(s) { return n>1e12 ? n/1000 : n }
            let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            return parser.date(from:s)?.timeIntervalSince1970 ?? ISO8601DateFormatter().date(from:s)?.timeIntervalSince1970
        }
        return nil
    }
    static func hook(agent: AgentID, raw: [String: Any]) throws -> AgentEvent? {
        guard [.workbuddy, .trae, .qwenwork, .dsh].contains(agent), let session = raw["session_id"] as? String, !session.isEmpty else { throw QWhaleMaidenError.message("hook 缺少受支持的 Agent 或 session_id") }
        if raw["subagent"] as? Bool == true || raw["parent_session_id"] as? String != nil { return nil }
        if agent == .dsh { return try dsh(raw:raw,session:session) }
        let name = raw["hook_event_name"] as? String ?? ""
        var type: String
        var summary: String?
        switch name {
        case "UserPromptSubmit": type = "turn.started"
        case "PreToolUse", "PostToolUse":
            let tool=raw["tool_name"] as? String ?? ""
            if agent == .qwenwork && name == "PreToolUse" && ["ask_user_question","AskUserQuestion","request_user_input"].contains(tool) { type="attention.requested";summary="需要你回答" }
            else { type = "turn.active" }
        case "PermissionRequest": type = "attention.requested"; summary = "需要批准权限"
        case "Notification":
            let kind = raw["notification_type"] as? String ?? ""
            let waits = ["permission_prompt":"需要批准权限", "ask_user_question":"需要你回答", "document_review":"需要审阅文档", "browser_interaction":"需要浏览器确认", "elicitation_dialog":"需要补充信息"]
            if let text = waits[kind] { type = "attention.requested"; summary = text }
            else if agent == .trae && kind == "idle_prompt" { type = "turn.ended" }
            else { return nil }
        case "Stop": if raw["stop_hook_active"] as? Bool == true { return nil }; type = "turn.ended"
        case "StopFailure": if agent == .qwenwork { return nil };type = "task.failed"
        case "Interrupt": type = "task.cancelled"
        default: return nil
        }
        // Never copy prompts, tool arguments or commands into persistence.
        return AgentEvent(eventId: raw["event_id"] as? String ?? UUID().uuidString, agent: agent, sessionId: session, turnId: raw["turn_id"] as? String, type: type, source: "hook", requestId: raw["request_id"] as? String ?? raw["tool_use_id"] as? String, summary: summary)
    }

    static func dsh(raw:[String:Any],session:String) throws -> AgentEvent? {
        let name=raw["event_type"] as? String ?? "",reason=raw["reason"] as? String ?? ""
        let tool=raw["tool_name"] as? String ?? ""
        var type:String;var summary:String?
        switch name {
        case "turn/start":type="turn.started"
        case "tool/call":
            if tool == "ask_user_question" { type="attention.requested";summary="需要你回答" } else { type="turn.active" }
        case "tool/result":type=raw["resolves_wait"] as? Bool == true ? "attention.resolved" : "turn.active"
        case "approval/asked":type="attention.requested";summary="需要批准权限"
        case "turn/end":
            switch reason {
            case "completed":type="turn.ended"
            case "blocked":type="attention.requested";summary="需要你处理"
            case "error","max-tokens","timeout":type="task.failed"
            case "aborted","cancelled","canceled":type="task.cancelled"
            default:type="source.disconnected"
            }
        case "source/disconnected":type="source.disconnected"
        default:return nil
        }
        guard let id=raw["event_id"] as? String,let turn=raw["turn_id"] as? String,!id.isEmpty,!turn.isEmpty else { throw QWhaleMaidenError.message("DSH 桥接缺少事件或回合身份") }
        return AgentEvent(eventId:id,agent:.dsh,sessionId:session,turnId:turn,type:type,sequence:(raw["sequence"] as? NSNumber)?.int64Value,source:"dsh-plugin:"+(raw["epoch"] as? String ?? "unknown"),requestId:raw["request_id"] as? String,summary:summary)
    }

    static func log(agent: AgentID, raw: [String: Any], cursor: inout LogCursor, eventID: String, offset: UInt64) -> AgentEvent? {
        var type: String?
        var request: String?
        var summary: String?
        var title: String?
        if agent == .codex {
            let payload = raw["payload"] as? [String: Any] ?? [:]
            let recordType = raw["type"] as? String
            if recordType == "session_meta" {
                cursor.session = payload["id"] as? String ?? cursor.session
                let source = payload["source"] as? [String: Any]
                cursor.auxiliary = source?["subagent"] != nil
                return nil
            }
            if cursor.auxiliary { return nil }
            if recordType == "event_msg" {
                switch payload["type"] as? String {
                case "task_started": cursor.turn = payload["turn_id"] as? String ?? eventID; cursor.waiting = false; cursor.waitCallId = nil; type = "turn.started"
                case "task_complete": if !cursor.waiting { type = "turn.ended" }
                case "turn_aborted": cursor.waiting = false; type = "task.cancelled"
                case "approval_request", "permission_request": type = "attention.requested"; summary = "需要批准权限"; request = payload["request_id"] as? String ?? eventID; cursor.waiting = true
                case "request_user_input": type = "attention.requested"; summary = "需要你回答"; request = payload["call_id"] as? String ?? eventID; cursor.waiting = true
                default: break
                }
            } else if recordType == "response_item", let ptype = payload["type"] as? String {
                if ["function_call", "custom_tool_call"].contains(ptype) {
                    let name = payload["name"] as? String ?? ""
                    if name.hasSuffix("request_user_input") || name.hasSuffix("request_user_input_async") {
                        cursor.waiting = true; cursor.waitCallId = payload["call_id"] as? String; cursor.waitAsync = name.hasSuffix("request_user_input_async"); type = "attention.requested"; summary = "需要你回答"; request = cursor.waitCallId ?? eventID
                    } else if !cursor.waiting { type = "turn.active" }
                } else if ["function_call_output", "custom_tool_call_output"].contains(ptype), cursor.waiting, let call=cursor.waitCallId, payload["call_id"] as? String == call {
                    if !cursor.waitAsync { cursor.waiting = false; cursor.waitCallId = nil; type = "attention.resolved" }
                } else if ptype == "message", payload["role"] as? String == "user", cursor.waiting {
                    cursor.waiting = false; cursor.waitCallId = nil; type = "attention.resolved"
                }
                // An async tool's {accepted:true} is not the user's answer.
            }
        } else if agent == .lingxi {
            cursor.session = String(describing: raw["session_id"] ?? cursor.session)
            var content = raw["content"] as? [String: Any] ?? [:]
            if let string = raw["content"] as? String, let data = string.data(using: .utf8) { content = jsonObject(data) ?? [:] }
            switch raw["type"] as? String {
            case "user.input": cursor.waiting = false; cursor.turn = eventID; type = "turn.started"
            case "run.start": cursor.waiting = false; cursor.turn = content["run_id"] as? String ?? String(describing: raw["group_id"] ?? eventID); type = "turn.started"
            case "run.end": if !cursor.waiting { type = "turn.ended" }
            case "run.cancelled", "run.canceled": cursor.waiting = false; type = "task.cancelled"
            case "run.error": cursor.waiting = false; type = "task.failed"
            case "component.start":
                if content["type"] as? String == "c_ask_user_question" { cursor.waiting = true; type = "attention.requested"; summary = "需要你回答"; request = String(describing: raw["id"] ?? eventID) }
                else if !cursor.waiting { type = "turn.active" }
            default: break
            }
            title = "灵犀任务"
        }
        guard let mapped = type else { return nil }
        return AgentEvent(eventId: eventID, agent: agent, sessionId: cursor.session, turnId: cursor.turn, type: mapped, sequence: Int64(offset), source: "local-log:" + cursor.generation, requestId: request, title: title, summary: summary, occurredAt:timestamp(raw["timestamp"] ?? raw["create_time"]))
    }
}

/// Bounded, incremental, read-only log consumer. State cursor commits with each accepted event.
final class LogAdapters {
    let core: PetCore
    let home: URL
    let startedAt: Date
    var report: [String: String] = [:]
    private var candidates: [(AgentID, URL)] = []
    private var lastScan: Double = 0
    private var baselines: [AgentID:Date] = [:]
    init(core: PetCore, home: URL = FileManager.default.homeDirectoryForCurrentUser, startedAt: Date = Date()) { self.core = core; self.home = home; self.startedAt = startedAt }
    func poll(forceScan: Bool = false) {
        let now = Date().timeIntervalSince1970
        if forceScan || now - lastScan > 15 { scan(); lastScan = now }
        for (agent, url) in candidates where !core.state.settings.disabledAgents.contains(agent) {
            do { try consume(agent: agent, url: url) } catch { report[agent.rawValue] = "读取失败：" + error.localizedDescription }
        }
    }
    private func scan() {
        var found: [(AgentID, URL)] = []
        let roots: [(AgentID, URL)] = [(.codex, home.appendingPathComponent(".codex/sessions")), (.lingxi, home.appendingPathComponent("Library/Application Support/WPS 灵犀/app-server-data/state/accounts"))]
        for (agent, root) in roots {
            if core.state.settings.disabledAgents.contains(agent) { report[agent.rawValue]="已关闭";continue }
            var files: [(URL, Date)] = []
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    guard (agent == .codex && url.pathExtension == "jsonl") || (agent == .lingxi && url.lastPathComponent == "rollout.jsonl") else { continue }
                    if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true { files.append((url, values.contentModificationDate ?? .distantPast)) }
                }
            }
            let selected = files.sorted { $0.1 > $1.1 }.prefix(64)
            found += selected.map { (agent, $0.0) }
            report[agent.rawValue] = selected.isEmpty ? "未找到本地日志" : "本地日志接入 · " + String(selected.count) + " 个近期文件（非官方接口）"
        }
        candidates = found
    }
    func consume(agent: AgentID, url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let creation = attributes[.creationDate] as? Date ?? .distantPast
        let key = agent.rawValue + ":" + digest(Data(url.path.utf8))
        let oldCursor = core.state.cursors[key]
        let session = agent == .lingxi ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent.components(separatedBy: "rollout-").last!
        var cursor = oldCursor ?? LogCursor(offset: creation >= (baselines[agent] ?? startedAt) ? 0 : size, inode: inode, generation: String(inode), session: session)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        if oldCursor == nil && agent == .codex {
            let head = try handle.read(upToCount: 64*1024) ?? Data()
            if let first = head.split(separator: 10).first, let obj = jsonObject(Data(first)), obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] {
                cursor.session = p["id"] as? String ?? cursor.session
                cursor.auxiliary = (p["source"] as? [String: Any])?["subagent"] != nil
            }
        }
        if cursor.inode != inode || cursor.offset > size { cursor.offset = 0; cursor.inode = inode; cursor.generation = String(inode) + ":" + UUID().uuidString; cursor.turn = nil; cursor.waiting = false }
        guard cursor.offset < size else { core.state.cursors[key] = cursor; return }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.read(upToCount: 2*1024*1024) ?? Data()
        let initial = cursor.offset
        var position = 0
        for newline in data.indices where data[newline] == 10 {
            let line = data.subdata(in: position..<newline)
            let eventOffset = initial + UInt64(position)
            cursor.offset = initial + UInt64(newline + 1)
            position = newline + 1
            if line.count > 1024*1024 { continue }
            if let raw = jsonObject(line) {
                let id = agent.rawValue + ":" + key.suffix(16) + ":" + cursor.generation + ":" + String(eventOffset)
                let event = AgentMapping.log(agent: agent, raw: raw, cursor: &cursor, eventID: id, offset: eventOffset)
                core.state.cursors[key] = cursor
                if let event = event {
                    do { try core.accept(event) }
                    catch { core.state.cursors[key] = oldCursor; throw error }
                }
            }
        }
        if position == 0 && data.count == 2*1024*1024 {
            // A single oversized record must not stall the consumer forever. Skip only complete records.
            report[agent.rawValue] = "日志单行过大，暂停该文件；其他来源正常"
            throw QWhaleMaidenError.message("日志记录超出读取预算")
        }
        core.state.cursors[key] = cursor
        // Newline-free partial UTF-8 tails remain unread until the next append.
        try core.save()
    }
    func resetBaseline(_ agent: AgentID) {
        baselines[agent]=Date()
        core.state.cursors=core.state.cursors.filter { !$0.key.hasPrefix(agent.rawValue+":") }
        core.state.tasks=core.state.tasks.filter { $0.value.agent != agent }
        poll(forceScan:true)
    }
}
