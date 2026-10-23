import Foundation
import Darwin

func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [UInt8(0)]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw QWhaleMaidenError.message("本地通道路径过长") }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

func configureSocket(_ fd: Int32) {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
}

func receiveExactly(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var position = 0
    while position < count {
        let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: position), count-position, 0) }
        guard n > 0 else { throw QWhaleMaidenError.message("本地通道超时或断开") }; position += n
    }
    return data
}
func sendAll(_ fd: Int32, data: Data) throws {
    var position = 0
    while position < data.count {
        let n = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: position), data.count-position, 0) }
        guard n > 0 else { throw QWhaleMaidenError.message("无法写入本地通道") }; position += n
    }
}
func receiveFrame(_ fd: Int32) throws -> Data {
    let header = try receiveExactly(fd, count: 4)
    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard size > 0 && size <= 256*1024 else { throw QWhaleMaidenError.message("事件超过大小上限") }
    return try receiveExactly(fd, count: Int(size))
}
func sendFrame(_ fd: Int32, data: Data) throws {
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) { try sendAll(fd, data: Data($0)) }; try sendAll(fd, data: data)
}

enum LocalChannel {
    static func path(dataRoot: URL) -> String {
        // UNIX paths have a 104-byte bound on macOS; the parent is private to the current user.
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("starbud-" + String(getuid()))
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return parent.appendingPathComponent(digest(Data(dataRoot.path.utf8)).prefix(16) + ".sock").path
    }
    static func request(path: String, object: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw QWhaleMaidenError.message("无法创建本地通道") }
        defer { close(fd) }; configureSocket(fd)
        var address = try socketAddress(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw QWhaleMaidenError.message("QWhaleMaiden未运行或通道不可用") }
        var uid:uid_t=0;var gid:gid_t=0
        guard getpeereid(fd,&uid,&gid) == 0,uid == getuid() else { throw QWhaleMaidenError.message("本地服务不属于当前用户") }
        try sendFrame(fd, data: JSONSerialization.data(withJSONObject: object))
        guard let reply = jsonObject(try receiveFrame(fd)) else { throw QWhaleMaidenError.message("无效的通道响应") }; return reply
    }
}

final class EventServer {
    private var fd: Int32 = -1
    let path: String
    private let queue = DispatchQueue(label: "starbud.socket")
    var handler: (([String: Any]) -> [String: Any])?
    init(path: String) { self.path = path }
    func start() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QWhaleMaidenError.message("无法创建本地通道") }
        // Bind the socket before allowing another instance to unlink it.
        if FileManager.default.fileExists(atPath: path) {
            if (try? LocalChannel.request(path: path, object: ["command":"ping"])) != nil { throw QWhaleMaidenError.message("QWhaleMaiden已经运行") }
            unlink(path)
        }
        var address = try socketAddress(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw QWhaleMaidenError.message("本地通道启动失败") }
        queue.async { [weak self] in self?.acceptLoop() }
    }
    private func acceptLoop() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            configureSocket(client)
            do {
                var uid: uid_t = 0; var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0 && uid == getuid() else { throw QWhaleMaidenError.message("拒绝其他用户") }
                guard let object = jsonObject(try receiveFrame(client)) else { throw QWhaleMaidenError.message("无效 JSON") }
                var reply: [String: Any] = ["ok":false, "error":"handler unavailable"]
                DispatchQueue.main.sync { reply = self.handler?(object) ?? reply }
                try sendFrame(client, data: JSONSerialization.data(withJSONObject: reply))
            } catch { try? sendFrame(client, data: JSONSerialization.data(withJSONObject: ["ok":false, "error":error.localizedDescription])) }
            close(client)
        }
    }
    func stop() { if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1; unlink(path) } }
}
