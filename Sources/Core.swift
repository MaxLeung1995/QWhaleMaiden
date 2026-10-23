import Foundation
import SQLite3
import CryptoKit

enum AgentID: String, Codable, CaseIterable {
    case codex, workbuddy, trae, lingxi, dsh, qwenwork
    var name: String { ["codex":"Codex", "workbuddy":"WorkBuddy", "trae":"Trae", "lingxi":"灵犀", "dsh":"DSH", "qwenwork":"千问办公"][rawValue]! }
    var bundleID: String { ["codex":"com.openai.codex", "workbuddy":"com.tencent.workbuddy.mac", "trae":"cn.trae.app", "lingxi":"com.wps.lingxi", "dsh":"com.deepseek.dsh", "qwenwork":"cn.qwenwork.desktop.mac"][rawValue]! }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func short(_ text: String, _ limit: Int = 120) -> String { String(text.replacingOccurrences(of: "\n", with: " ").prefix(limit)) }
func jsonObject(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

struct AgentEvent: Codable {
    var schemaVersion: Int = 1
    var eventId: String
    var agent: AgentID
    var sessionId: String
    var turnId: String?
    var type: String
    var sequence: Int64?
    var source: String = "hook"
    var requestId: String?
    var title: String?
    var summary: String?
    var occurredAt: Double?
}

struct TaskFact: Codable {
    var agent: AgentID
    var sessionId: String
    var turnId: String
    var source: String
    var status: String
    var title: String
    var summary: String
    var requestId: String?
    var sequence: Int64?
    var updatedAt: Double
    var key: String { agent.rawValue + ":" + sessionId }
    var noticeID: String { key + ":" + turnId + ":" + (requestId ?? status) }
}

struct Bubble: Codable {
    var id: String
    var agent: AgentID?
    var sessionId: String?
    var category: String
    var title: String
    var summary: String
    var priority: Int
    var createdAt: Double
    var expiresAt: Double?
    var action: String?
}

struct Suppression: Codable { var until: Double }
struct LogCursor: Codable {
    var offset: UInt64
    var inode: UInt64
    var generation: String
    var session: String
    var turn: String?
    var waiting: Bool = false
    var auxiliary: Bool = false
    var waitCallId: String?
    var waitAsync: Bool = false
}

struct PetSettings: Codable {
    var schemaVersion = 1
    var walk = true
    var whispers = true
    var reducedMotion = false
    // Optional so pre-sound snapshots decode without a destructive migration.
    var reminderSound: Bool?
    var preview = false
    var size: Double = 1
    var x: Double?
    var y: Double?
    var restEnabled = false
    var waterEnabled = false
    var restMinutes: Double = 50
    var waterMinutes: Double = 90
    var city: WeatherCity?
    var calendarEnabled = false
    var calendarIDs: [String] = []
    var calendarAlerts = false
    var disabledAgents: [AgentID] = []
    var selectedPack: String?
    var layoutVersion: Int?
    var menusOnRight: Bool?
}

struct StoredState: Codable {
    var schemaVersion = 1
    var tasks: [String: TaskFact] = [:]
    var suppressed: [String: Suppression] = [:]
    var cursors: [String: LogCursor] = [:]
    var settings = PetSettings()
    var reminders = ReminderClock()
    var weather: WeatherSnapshot?
    var emittedCalendarAlerts: [String: Double] = [:]
}

extension StoredState {
    enum CodingKeys: String, CodingKey { case schemaVersion,tasks,suppressed,cursors,settings,reminders,weather,emittedCalendarAlerts }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try c.decodeIfPresent(Int.self,forKey:.schemaVersion) ?? 1
        guard schemaVersion == 1 else { throw QWhaleMaidenError.message("状态版本较新，请使用对应版本应用") }
        tasks=try c.decodeIfPresent([String:TaskFact].self,forKey:.tasks) ?? [:]
        suppressed=try c.decodeIfPresent([String:Suppression].self,forKey:.suppressed) ?? [:]
        cursors=try c.decodeIfPresent([String:LogCursor].self,forKey:.cursors) ?? [:]
        settings=try c.decodeIfPresent(PetSettings.self,forKey:.settings) ?? PetSettings()
        reminders=try c.decodeIfPresent(ReminderClock.self,forKey:.reminders) ?? ReminderClock()
        weather=try c.decodeIfPresent(WeatherSnapshot.self,forKey:.weather)
        emittedCalendarAlerts=try c.decodeIfPresent([String:Double].self,forKey:.emittedCalendarAlerts) ?? [:]
    }
}

extension LogCursor {
    enum CodingKeys: String,CodingKey { case offset,inode,generation,session,turn,waiting,auxiliary,waitCallId,waitAsync }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        offset=try c.decode(UInt64.self,forKey:.offset);inode=try c.decode(UInt64.self,forKey:.inode)
        generation=try c.decode(String.self,forKey:.generation);session=try c.decode(String.self,forKey:.session)
        turn=try c.decodeIfPresent(String.self,forKey:.turn);waiting=try c.decodeIfPresent(Bool.self,forKey:.waiting) ?? false
        auxiliary=try c.decodeIfPresent(Bool.self,forKey:.auxiliary) ?? false
        waitCallId=try c.decodeIfPresent(String.self,forKey:.waitCallId);waitAsync=try c.decodeIfPresent(Bool.self,forKey:.waitAsync) ?? false
    }
}

enum QWhaleMaidenError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

/// One transactional snapshot plus a bounded event identity ledger. No raw conversations are stored.
final class StateStore {
    /// Preserve local settings through the product rename, including committed WAL data.
    /// No old logs or account data are copied. Custom/isolation data roots skip migration.
    static func migrateLegacyIfNeeded(from oldRoot:URL,to newRoot:URL) throws {
        let fm=FileManager.default,source=oldRoot.appendingPathComponent("state.sqlite"),target=newRoot.appendingPathComponent("state.sqlite")
        guard !fm.fileExists(atPath:target.path),fm.fileExists(atPath:source.path) else { return }
        var old:OpaquePointer?,new:OpaquePointer?
        guard sqlite3_open_v2(source.path,&old,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else { if old != nil { sqlite3_close(old) };throw QWhaleMaidenError.message("无法读取旧版状态，原数据已保留") }
        defer { sqlite3_close(old) }
        guard sqlite3_open(target.path,&new)==SQLITE_OK else { if new != nil { sqlite3_close(new) };throw QWhaleMaidenError.message("无法创建新版状态") }
        var copied=false
        defer { sqlite3_close(new);if !copied { try? fm.removeItem(at:target) } }
        guard let backup=sqlite3_backup_init(new,"main",old,"main") else { throw QWhaleMaidenError.message("无法迁移旧版状态") }
        let result=sqlite3_backup_step(backup,-1);sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else { throw QWhaleMaidenError.message("旧版状态暂不可用，请退出旧程序后重试；原数据已保留") }
        let packs=oldRoot.appendingPathComponent("packs"),destination=newRoot.appendingPathComponent("packs")
        if fm.fileExists(atPath:packs.path),!fm.fileExists(atPath:destination.path) { try fm.copyItem(at:packs,to:destination) }
        copied=true
    }
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw QWhaleMaidenError.message("无法打开状态数据库") }
        sqlite3_busy_timeout(db, 1500)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS snapshot(id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, seen REAL NOT NULL);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw QWhaleMaidenError.message("状态数据库事务失败") }
    }
    func load() throws -> StoredState {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM snapshot WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw QWhaleMaidenError.message("无法读取状态") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return StoredState() }
        let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(StoredState.self, from: data)
    }
    /// Returns false for an already committed identity. Cursor and state commit together.
    func commit(_ state: StoredState, eventId: String? = nil, now: Double = Date().timeIntervalSince1970) throws -> Bool {
        let data = try JSONEncoder().encode(state)
        try execute("BEGIN IMMEDIATE")
        do {
            if let id = eventId {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO events(id,seen) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK else { throw QWhaleMaidenError.message("无法写入事件标识") }
                sqlite3_bind_text(statement, 1, id, -1, transient); sqlite3_bind_double(statement, 2, now)
                let result = sqlite3_step(statement); sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw QWhaleMaidenError.message("无法提交事件") }
                if sqlite3_changes(db) == 0 { try execute("ROLLBACK"); return false }
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO snapshot(id,data) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw QWhaleMaidenError.message("无法保存状态") }
            data.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
            let result = sqlite3_step(statement); sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw QWhaleMaidenError.message("无法保存状态") }
            try execute("DELETE FROM events WHERE seen < \(now - 7 * 86400); DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY seen DESC LIMIT -1 OFFSET 100000); COMMIT")
            return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
}

final class PetCore {
    var state: StoredState
    let store: StateStore
    var ephemeral: [Bubble] = []
    var lastError: String?
    var onAccepted: ((AgentEvent) -> Void)?
    init(store: StateStore) throws {
        self.store = store; state = try store.load()
        if state.reminders.focusMode == "stopped" { state.reminders.command("cancel") }
    }
    func save() throws { _ = try store.commit(state) }

    @discardableResult func accept(_ event: AgentEvent, now: Double = Date().timeIntervalSince1970) throws -> Bool {
        let allowed = ["turn.started", "turn.active", "turn.ended", "attention.requested", "attention.resolved", "task.failed", "task.cancelled", "source.disconnected"]
        guard event.schemaVersion == 1, !event.eventId.isEmpty, event.eventId.utf8.count <= 512, !event.sessionId.isEmpty, event.sessionId.utf8.count <= 200, allowed.contains(event.type) else { throw QWhaleMaidenError.message("不支持的事件或身份") }
        if state.settings.disabledAgents.contains(event.agent) { return false }
        let before = state
        let key = event.agent.rawValue + ":" + event.sessionId
        let old = state.tasks[key]
        if let seq = event.sequence, let previous = old?.sequence, old?.source == event.source, seq <= previous { return false }
        if [.dsh,.qwenwork].contains(event.agent),old?.status == "waiting" {
            if ["turn.active","turn.ended"].contains(event.type) { return false }
            if event.type == "attention.resolved",event.requestId != old?.requestId { return false }
        }
        let starts = event.type == "turn.started"
        if !starts, let turn = event.turnId, let old = old, turn != old.turnId { return false }
        let turn = event.turnId ?? (starts ? event.eventId : old?.turnId) ?? event.eventId
        if starts, let old = old, old.turnId == turn, old.status != "active" { return false }
        var task = old ?? TaskFact(agent: event.agent, sessionId: event.sessionId, turnId: turn, source: event.source, status: "unknown", title: event.agent.name, summary: "", updatedAt: now)
        if starts { task.turnId = turn; task.requestId = nil }
        if !starts && ["ended", "failed", "cancelled"].contains(task.status) && ["turn.active", "attention.requested"].contains(event.type) { return false }
        let observed = event.occurredAt.flatMap { $0.isFinite && $0 > 0 && $0 <= now+300 ? $0 : nil } ?? now
        task.source = event.source; task.sequence = event.sequence ?? task.sequence; task.updatedAt = observed
        if let title = event.title, !title.isEmpty { task.title = short(title, 50) }
        switch event.type {
        case "turn.started", "turn.active", "attention.resolved": task.status = "active"; task.requestId = nil; task.summary = "正在工作"
        case "attention.requested": task.status = "waiting"; task.requestId = event.requestId ?? task.requestId ?? event.eventId; task.summary = short(event.summary ?? "需要你确认")
        case "turn.ended": task.status = "ended"; task.requestId = nil; task.summary = "本轮回复结束"
        case "task.failed": task.status = "failed"; task.requestId = nil; task.summary = "本轮执行失败"
        case "task.cancelled": task.status = "cancelled"; task.requestId = nil; task.summary = "已取消"
        default: task.status = "unknown"; task.summary = "连接中断，状态待核实"
        }
        let transition = old?.status != task.status || old?.turnId != task.turnId || old?.requestId != task.requestId
        if !transition, event.type != "turn.active", let old=old { task.updatedAt=old.updatedAt }
        state.tasks[key] = task
        // High-frequency activity has no new user-visible transition. The log consumer
        // commits its cursor once per bounded batch; important edges remain transactional.
        if !transition && event.type == "turn.active" { return true }
        // Keep unresolved facts, prune only resolved history first.
        for (key, value) in state.tasks where ["ended", "failed", "cancelled"].contains(value.status) && now - value.updatedAt > 86400 { state.tasks.removeValue(forKey: key) }
        if state.tasks.count > 1000, old == nil { state = before; throw QWhaleMaidenError.message("任务状态已达上限，请清理状态") }
        do {
            let inserted = try store.commit(state, eventId: event.eventId, now: now)
            if !inserted { state = before }
            else if transition { onAccepted?(event) }
            return inserted
        } catch { state = before; throw error }
    }

    func bubbles(now: Double = Date().timeIntervalSince1970) -> [Bubble] {
        var items = ephemeral.filter { ($0.expiresAt ?? .greatestFiniteMagnitude) > now }
        for task in state.tasks.values where !state.settings.disabledAgents.contains(task.agent) {
            guard task.status != "active", task.status != "unknown" else { continue }
            let waiting = task.status == "waiting"
            if !waiting && now - task.updatedAt > 60 { continue }
            let stale = waiting && now - task.updatedAt > 86400
            items.append(Bubble(id: task.noticeID, agent: task.agent, sessionId: task.sessionId, category: task.status, title: task.agent.name + (state.settings.preview ? " · " + task.title : ""), summary: stale ? "状态较久未更新，请回到应用核实" : (state.settings.preview || !waiting ? task.summary : "需要你处理"), priority: waiting ? 100 : (task.status == "failed" ? 75 : 60), createdAt: task.updatedAt, expiresAt: waiting ? nil : task.updatedAt + 60, action: "openAgent"))
        }
        return items.filter { (state.suppressed[$0.id]?.until ?? 0) <= now }.sorted { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority > $1.priority }
    }
    func suppress(_ id: String, until: Double = .greatestFiniteMagnitude) throws {
        let old = state
        state.suppressed[id] = Suppression(until: until)
        if state.suppressed.count > 3000 {
            let live=Set(state.tasks.values.map(\.noticeID)+ephemeral.map(\.id))
            state.suppressed=state.suppressed.filter { live.contains($0.key) && $0.value.until > Date().timeIntervalSince1970 }
        }
        do { try save() } catch { state = old; throw error }
    }
    func addBubble(id: String = UUID().uuidString, category: String, title: String, summary: String, priority: Int, action: String? = nil, lifetime: Double = 60, now: Double = Date().timeIntervalSince1970) {
        ephemeral.removeAll { $0.id == id || ($0.expiresAt ?? 0) <= now }
        ephemeral.append(Bubble(id: id, category: category, title: title, summary: summary, priority: priority, createdAt: now, expiresAt: now + lifetime, action: action))
        if ephemeral.count > 64 { ephemeral.removeFirst(ephemeral.count - 64) }
    }
    var activity: String {
        let tasks = state.tasks.values.filter { !state.settings.disabledAgents.contains($0.agent) }
        if tasks.contains(where: { $0.status == "waiting" }) { return "wait" }
        if tasks.contains(where: { $0.status == "active" && Date().timeIntervalSince1970 - $0.updatedAt < 1800 }) { return "think" }
        return "idle"
    }
}

struct BubbleSelection {
    var selectedID: String?
    var lockID: String?
    var lastAdvance: Double = 0
    mutating func select(_ items: [Bubble], now: Double, delta: Int = 0) -> Bubble? {
        guard !items.isEmpty else { selectedID = nil; return nil }
        if let lockID = lockID, let locked = items.first(where: { $0.id == lockID }) { return locked }
        if !items.contains(where: { $0.id == selectedID }) {
            let first=items.max { $0.priority < $1.priority }!
            selectedID=first.id;lastAdvance=now
            if delta == 0 { return first }
        }
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let top = items.map(\.priority).max() ?? 0
        var next = index
        if items[index].priority < top { next = items.firstIndex(where: { $0.priority == top }) ?? 0 }
        if delta != 0 { next = (index + delta + items.count) % items.count; lastAdvance = now }
        else if now - lastAdvance >= (items[index].category == "waiting" ? 6 : 8) {
            if items[index].category != "waiting" { selectedID = nil; return nil }
            let peers = items.indices.filter { items[$0].priority == top }
            if let p = peers.firstIndex(of: index) { next = peers[(p + 1) % peers.count] }
            lastAdvance = now
        }
        if selectedID == nil || selectedID != items[next].id { lastAdvance = now }
        selectedID = items[next].id
        return items[next]
    }
}

struct ReminderClock: Codable {
    var rest: Double = 0
    var water: Double = 0
    static let workSeconds: Double = 45 * 60
    var focusRemaining: Double = ReminderClock.workSeconds
    var focusMode = "stopped"
    var focusPhase = "work"
    var focusCycle = UUID().uuidString
    var restSnooze: Double?
    var waterSnooze: Double?
    mutating func advance(seconds: Double, settings: PetSettings) -> [String] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        var result: [String] = []
        if settings.restEnabled {
            if let remaining=restSnooze { restSnooze=max(0,remaining-seconds);if restSnooze == 0 { result.append("rest");restSnooze=nil;rest=0 } }
            else { rest += seconds;if rest >= settings.restMinutes*60 { result.append("rest");rest=0 } }
        }
        if settings.waterEnabled {
            if let remaining=waterSnooze { waterSnooze=max(0,remaining-seconds);if waterSnooze == 0 { result.append("water");waterSnooze=nil;water=0 } }
            else { water += seconds;if water >= settings.waterMinutes*60 { result.append("water");water=0 } }
        }
        if focusMode == "running" {
            focusRemaining = max(0, focusRemaining - seconds)
            if focusRemaining == 0 { focusMode = "finished"; result.append("focus:" + focusCycle) }
        }
        return result
    }
    mutating func command(_ command: String) {
        switch command {
        case "start": focusPhase = "work"; focusRemaining = Self.workSeconds; focusCycle = UUID().uuidString; focusMode = "running"
        case "break": focusPhase = "break"; focusRemaining = 5*60; focusCycle = UUID().uuidString; focusMode = "running"
        case "pause": if focusMode == "running" { focusMode = "paused" }
        case "resume": if focusMode == "paused" { focusMode = "running" }
        case "cancel": focusPhase = "work"; focusMode = "stopped"; focusRemaining = Self.workSeconds
        case "rest": rest = 0;restSnooze=nil
        case "water": water = 0;waterSnooze=nil
        default: break
        }
    }
    mutating func sleep() { rest = 0; water = 0;restSnooze=nil;waterSnooze=nil;command("pause") }
}

struct WeatherCity: Codable { var name: String; var latitude: Double; var longitude: Double; var timezone: String }
struct WeatherSnapshot: Codable { var city: String; var temperature: Double; var code: Int; var validAt: String; var fetchedAt: Double }

/// Local-only non-repeating decks shared by automatic and manually requested chatter.
struct ChatterDeck {
    let lines: [String:[String]]
    private var bags: [String:[String]] = [:]
    private var last: [String:String] = [:]
    init(url: URL) throws { lines = try JSONDecoder().decode([String:[String]].self,from:Data(contentsOf:url)) }
    init(lines: [String:[String]]) { self.lines=lines }
    mutating func next(_ group: String) -> String {
        let pool=lines[group] ?? lines["idle"] ?? []
        guard !pool.isEmpty else { return "" }
        if bags[group]?.isEmpty != false {
            var bag=Array(Set(pool)).shuffled()
            if bag.count>1,bag.last == last[group] { bag.swapAt(0,bag.count-1) }
            bags[group]=bag
        }
        let text=bags[group]!.removeLast();last[group]=text;return text
    }
}

/// Recognizes three short, separate three-finger contacts. No coordinates or touch data are retained.
struct TripleThreeTapRecognizer {
    private var start: Double?
    private var peak = 0
    private var invalid = false
    private var tapEnds: [Double] = []
    private var lastTimestamp: Double?
    mutating func reset() { start=nil;peak=0;invalid=false;tapEnds=[];lastTimestamp=nil }
    mutating func feed(contacts: Int, at time: Double) -> Bool {
        guard time.isFinite,time>=0,(0...16).contains(contacts) else { reset();return false }
        if let last=lastTimestamp,time<last { reset() };lastTimestamp=time
        if contacts>0 {
            if start == nil { start=time;peak=contacts;invalid=false }
            peak=max(peak,contacts);invalid = invalid || contacts>3 || time-(start ?? time)>0.5
            return false
        }
        guard let began=start else { return false }
        let qualifies = peak == 3 && !invalid && time-began>=0.025 && time-began<=0.5
        start=nil;peak=0;invalid=false
        guard qualifies else { tapEnds=[];return false }
        if let last=tapEnds.last,time-last>0.8 { tapEnds=[] }
        tapEnds.append(time)
        if tapEnds.count>=3,time-(tapEnds.first ?? time)<=2 { reset();return true }
        return false
    }
}

/// A small, local presentation for wellness reminders; no task or timer mutation here.
struct WellnessReminder {
    let kind: String
    let title: String
    let message: String
    let animation: String
    var category: String { kind == "focusBreak" ? "focus" : kind }
    var sound: String { category }
    var priority: Int { category == "focus" ? 75 : 40 }
    init?(kind: String, phase: String = "work") {
        self.kind = kind == "focus" && phase == "break" ? "focusBreak" : kind
        switch self.kind {
        case "focus": title="专注完成";message="辛苦啦，抬头看看远处吧。";animation="点击回应-开心跃动"
        case "focusBreak": title="休息结束";message="慢慢收心，准备好再出发。";animation="点击回应-元气挥手"
        case "rest": title="休息一下";message="肩膀放松，起来伸个懒腰吧。";animation="超大伸懒腰"
        case "water": title="喝口水吧";message="喝口温水吧，我陪你慢慢来。";animation="鲸鱼吐泡泡特效"
        default: return nil
        }
    }
}
