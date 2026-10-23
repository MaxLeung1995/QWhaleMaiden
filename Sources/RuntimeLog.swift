import Foundation

final class RuntimeLog {
    let directory: URL
    private let queue=DispatchQueue(label:"starbud.runtime-log",qos:.utility)
    private let session=UUID().uuidString
    private let limit: Int
    private let retained: Int
    private let formatter=ISO8601DateFormatter()
    init(directory: URL, limit: Int=2*1024*1024, retained: Int=3) {
        self.directory=directory;self.limit=limit;self.retained=retained
        formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    func record(_ event: String, level: String="info", _ fields: [String:Any]=[:]) {
        // Call sites supply technical state only; never task summaries, prompts, or calendar content.
        queue.async { [self] in
            var safe:[String:Any]=[:]
            for (key,value) in fields {
                if let number=value as? NSNumber,number.doubleValue.isFinite { safe[key]=number }
                else if let text=value as? String { safe[key]=String(text.prefix(512)) }
                else if let values=value as? [Any],values.count<=16 {
                    let numbers=values.compactMap { ($0 as? NSNumber)?.doubleValue }
                    if numbers.count==values.count && numbers.allSatisfy(\.isFinite) { safe[key]=numbers }
                }
            }
            let object:[String:Any]=["timestamp":formatter.string(from:Date()),"session":session,"level":level,"event":String(event.prefix(80)),"fields":safe]
            guard let data=try? JSONSerialization.data(withJSONObject:object),data.count<16*1024 else { return }
            let fm=FileManager.default,url=directory.appendingPathComponent("runtime.jsonl")
            if let size=(try? fm.attributesOfItem(atPath:url.path)[.size]) as? NSNumber,size.intValue+data.count+1>limit {
                for i in stride(from:retained,through:1,by:-1) {
                    let destination=directory.appendingPathComponent("runtime.\(i).jsonl")
                    try? fm.removeItem(at:destination)
                    let source=i==1 ? url : directory.appendingPathComponent("runtime.\(i-1).jsonl")
                    if fm.fileExists(atPath:source.path) { try? fm.moveItem(at:source,to:destination) }
                }
            }
            if !fm.fileExists(atPath:url.path) { fm.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) }
            if let file=try? FileHandle(forWritingTo:url) { defer { try? file.close() };do { try file.seekToEnd();try file.write(contentsOf:data);try file.write(contentsOf:Data([10])) } catch {} }
        }
    }
    func flush() { queue.sync {} }
}
