import AppKit
import EventKit
import Foundation

final class WeatherService {
    private let session: URLSession
    private var request: URLSessionDataTask?
    private var generation = UUID()
    private var lastAttempt: Double = 0
    var error: String?
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }
    func search(_ name: String, completion: @escaping (Result<[WeatherCity], Error>) -> Void) {
        guard name.count >= 2, name.count <= 80 else { completion(.failure(QWhaleMaidenError.message("请输入至少两个字的城市名"))); return }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name:"name",value:name), URLQueryItem(name:"count",value:"8"), URLQueryItem(name:"language",value:"zh"), URLQueryItem(name:"format",value:"json")]
        session.dataTask(with: url.url!) { data, response, failure in
            var result: Result<[WeatherCity], Error>
            if let failure = failure { result = .failure(failure) }
            else if (response as? HTTPURLResponse)?.statusCode == 200, let data = data, let obj = jsonObject(data) {
                let cities = (obj["results"] as? [[String: Any]] ?? []).compactMap { item -> WeatherCity? in
                    guard let lat = item["latitude"] as? Double, let lon = item["longitude"] as? Double, let name = item["name"] as? String else { return nil }
                    return WeatherCity(name: name + " · " + (item["admin1"] as? String ?? item["country"] as? String ?? ""), latitude: lat, longitude: lon, timezone: item["timezone"] as? String ?? "UTC")
                }; result = .success(cities)
            } else { result = .failure(QWhaleMaidenError.message("城市搜索暂时不可用")) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
    func refresh(core: PetCore, manual: Bool = false, completion: @escaping () -> Void) {
        guard let city = core.state.settings.city else { return }
        let now = Date().timeIntervalSince1970
        if now-lastAttempt < 300 { completion(); return }
        if !manual, let cached = core.state.weather, cached.city == city.name, now-cached.fetchedAt < 1800 { completion(); return }
        lastAttempt = now; request?.cancel(); generation = UUID(); let expected = generation
        var url = URLComponents(string:"https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name:"latitude",value:String(city.latitude)), URLQueryItem(name:"longitude",value:String(city.longitude)), URLQueryItem(name:"current",value:"temperature_2m,weather_code,is_day"), URLQueryItem(name:"timezone",value:city.timezone)]
        request = session.dataTask(with: url.url!) { [weak self] data, response, failure in
            DispatchQueue.main.async {
                guard let self = self, self.generation == expected, core.state.settings.city?.name == city.name else { return }
                if let failure = failure { self.error = "天气更新失败：" + failure.localizedDescription }
                else if (response as? HTTPURLResponse)?.statusCode == 200, let data = data, let obj = jsonObject(data), let current = obj["current"] as? [String: Any], let temp = current["temperature_2m"] as? Double, temp.isFinite, let code = current["weather_code"] as? Int {
                    core.state.weather = WeatherSnapshot(city:city.name, temperature:temp, code:code, validAt:current["time"] as? String ?? "", fetchedAt:now)
                    do { try core.save(); self.error = nil } catch { self.error = error.localizedDescription }
                } else { self.error = "天气服务暂时不可用，保留上次数据" }
                completion()
            }
        }; request?.resume()
    }
    func selectCity(_ city: WeatherCity, core: PetCore) throws {
        guard city.latitude.isFinite, city.longitude.isFinite, abs(city.latitude) <= 90, abs(city.longitude) <= 180, TimeZone(identifier:city.timezone) != nil else { throw QWhaleMaidenError.message("无效城市") }
        request?.cancel(); generation = UUID(); lastAttempt = 0
        core.state.settings.city = city; core.state.weather = nil; try core.save()
    }
}

struct CalendarItem: Codable {
    var id: String
    var title: String
    var start: Double
    var end: Double
    var allDay: Bool
}

final class CalendarService {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    var items: [CalendarItem] = []
    var calendars: [[String: String]] = []
    var status = "尚未启用日历"
    var changed: (() -> Void)?
    private var reloadJob: DispatchWorkItem?
    private var alertIDs = Set<String>()
    init() {
        observer = NotificationCenter.default.addObserver(forName:.EKEventStoreChanged, object:nil, queue:.main) { [weak self] _ in
            self?.reloadJob?.cancel()
            let job = DispatchWorkItem { [weak self] in self?.changed?() }
            self?.reloadJob = job; DispatchQueue.main.asyncAfter(deadline:.now()+0.5, execute:job)
        }
    }
    var authorized: Bool {
        let authorization = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return authorization == .fullAccess }
        return authorization == .authorized
    }
    func enable(core: PetCore, completion: @escaping () -> Void) {
        let finish: (Bool, Error?) -> Void = { [weak self] granted, error in
            DispatchQueue.main.async {
                core.state.settings.calendarEnabled = granted
                do { try core.save() } catch { self?.status = error.localizedDescription }
                self?.status = granted ? "日历已连接" : "未获得日历读取权限，可在系统设置中更改"
                self?.refresh(core:core); completion()
            }
        }
        if #available(macOS 14.0, *) { store.requestFullAccessToEvents(completion:finish) }
        else { store.requestAccess(to:.event, completion:finish) }
    }
    func refresh(core: PetCore) {
        guard core.state.settings.calendarEnabled, authorized else {
            items = []; calendars = []; core.ephemeral.removeAll { $0.category == "calendar" }; alertIDs = []
            status = core.state.settings.calendarEnabled ? "日历权限不可用" : "尚未启用日历"; return
        }
        let all = store.calendars(for:.event)
        calendars = all.map { ["id":$0.calendarIdentifier, "title":$0.title] }
        // Empty selection means none, not all. First permission grant deliberately picks calendars.
        if core.state.settings.calendarIDs.isEmpty { status = "请选择要显示的日历"; items = []; return }
        let selected = all.filter { core.state.settings.calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { items = []; status = "所选日历已不存在，请重新选择"; return }
        let start = Calendar.current.startOfDay(for:Date())
        let end = Calendar.current.date(byAdding:.day, value:7, to:start)!
        let predicate = store.predicateForEvents(withStart:start, end:end, calendars:selected)
        items = store.events(matching:predicate).sorted { $0.startDate < $1.startDate }.prefix(200).map {
            CalendarItem(id:digest(Data((($0.calendar?.calendarIdentifier ?? "") + ":" + ($0.calendarItemIdentifier) + ":" + String($0.startDate.timeIntervalSince1970)).utf8)), title:short($0.title ?? "未命名日程", 80), start:$0.startDate.timeIntervalSince1970, end:$0.endDate.timeIntervalSince1970, allDay:$0.isAllDay)
        }
        let validIDs = Set(items.map { "calendar:"+$0.id })
        core.ephemeral.removeAll { $0.category == "calendar" && !validIDs.contains($0.id) }
        status = "只读 · " + String(selected.count) + " 个日历"
    }
    func tick(core: PetCore, now: Double) {
        guard core.state.settings.calendarEnabled, authorized else {
            if !items.isEmpty { refresh(core:core) }; return
        }
        guard core.state.settings.calendarAlerts else { core.ephemeral.removeAll { $0.category == "calendar" }; return }
        for event in items where !event.allDay && event.start > now && event.start-now <= 600 {
            let id = "calendar:" + event.id
            guard !alertIDs.contains(id), core.state.suppressed[id] == nil, core.state.emittedCalendarAlerts[id] == nil else { continue }
            alertIDs.insert(id)
            core.state.emittedCalendarAlerts[id] = now
            core.state.emittedCalendarAlerts = core.state.emittedCalendarAlerts.filter { now-$0.value < 8*86400 }
            do { try core.save() } catch { status="日程提醒保存失败";core.state.emittedCalendarAlerts.removeValue(forKey:id);continue }
            core.addBubble(id:id, category:"calendar", title:"日程即将开始", summary:core.state.settings.preview ? event.title : "10 分钟内有日程", priority:90, action:"calendar", lifetime:min(600,event.start-now), now:now)
        }
    }
}

enum LaunchRouter {
    static func appURL(_ agent: AgentID) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier:agent.bundleID) }
    static func open(_ agent: AgentID, completion: @escaping (Error?) -> Void) {
        guard let url = appURL(agent) else { completion(QWhaleMaidenError.message("未找到 \(agent.name)，请安装或在设置中查看接入状态")); return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at:url, configuration:configuration) { _, error in DispatchQueue.main.async { completion(error) } }
    }
    static func calendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.iCal") { NSWorkspace.shared.openApplication(at:url, configuration:NSWorkspace.OpenConfiguration()) }
    }
}
