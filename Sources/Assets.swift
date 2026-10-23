import Foundation
import ImageIO
import WebKit

struct PackAction: Codable {
    var file: String
    var frames: Int?
    var frameWidth: Int?
    var frameHeight: Int?
    var fps: Double?
}
struct PackManifest: Codable {
    var schemaVersion: Int
    var packId: String
    var version: String
    var name: String
    var license: String
    var renderer: String
    var actions: [String: PackAction]
}
struct InstalledPack: Codable { var id: String; var manifest: PackManifest }

final class SVGGuard: NSObject, XMLParserDelegate {
    var valid = true
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        if ["script", "foreignobject", "iframe", "audio", "video", "animate", "set"].contains(elementName.lowercased()) { valid = false }
        for (name, value) in attributes {
            let name = name.lowercased(); let lower = value.lowercased()
            if name.hasPrefix("on") { valid = false }
            if name == "xml:base" { valid = false }
            if name == "href" || name.hasSuffix(":href") { if !value.hasPrefix("#") { valid = false } }
            if lower.contains("url(") {
                let expression = try! NSRegularExpression(pattern:"url\\(([^)]*)\\)",options:.caseInsensitive)
                let range=NSRange(value.startIndex..<value.endIndex,in:value)
                for match in expression.matches(in:value,range:range) {
                    guard let r=Range(match.range(at:1),in:value) else { valid=false;continue }
                    let reference=value[r].trimmingCharacters(in:CharacterSet(charactersIn:" \t\n\"'"))
                    if reference.range(of:"^#[A-Za-z0-9_-]+$",options:.regularExpression) == nil { valid=false }
                }
                if lower.components(separatedBy:"url(").count-1 != expression.numberOfMatches(in:value,range:range) { valid=false }
            }
            if lower.contains("javascript:") || lower.contains("@import") { valid = false }
        }
    }
    static func validate(_ data: Data) throws {
        guard data.count <= 5*1024*1024, let text = String(data:data,encoding:.utf8), !text.lowercased().contains("<!doctype"), !text.lowercased().contains("<!entity"), !text.lowercased().contains("<style") else { throw QWhaleMaidenError.message("SVG 必须自包含，不含脚本、样式块或外部实体") }
        let validator = SVGGuard(); let parser = XMLParser(data:data); parser.shouldResolveExternalEntities = false; parser.delegate = validator
        guard parser.parse(), validator.valid else { throw QWhaleMaidenError.message("SVG 包含不允许的内容") }
    }
}

final class AssetPackManager {
    let root: URL
    init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true) }
    func list() -> [InstalledPack] {
        ((try? FileManager.default.contentsOfDirectory(at:root, includingPropertiesForKeys:nil)) ?? []).compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."), let m = try? validate(directory:url) else { return nil }
            return InstalledPack(id:url.lastPathComponent,manifest:m)
        }.sorted { $0.manifest.name < $1.manifest.name }
    }
    static func safeRelative(_ file: String) -> Bool {
        let parts = file.split(separator:"/", omittingEmptySubsequences:false)
        return !file.isEmpty && file.utf8.count < 240 && !file.contains("\\") && !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) && file.range(of:"^[A-Za-z0-9_./-]+$",options:.regularExpression) != nil
    }
    func validate(directory: URL) throws -> PackManifest {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at:directory, includingPropertiesForKeys:[.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { throw QWhaleMaidenError.message("无法读取素材目录") }
        var total = 0; var count = 0
        for case let file as URL in enumerator {
            let v = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
            guard v.isSymbolicLink != true else { throw QWhaleMaidenError.message("素材包不允许符号链接") }
            if v.isRegularFile == true { total += v.fileSize ?? 0; count += 1 }
            guard total <= 200*1024*1024 && count <= 512 else { throw QWhaleMaidenError.message("素材包超过 200 MiB 或 512 文件上限") }
        }
        let manifestData = try Data(contentsOf:directory.appendingPathComponent("manifest.json"))
        guard manifestData.count <= 64*1024 else { throw QWhaleMaidenError.message("素材清单过大") }
        let manifest = try JSONDecoder().decode(PackManifest.self,from:manifestData)
        guard manifest.schemaVersion == 1, ["svg","spritesheet"].contains(manifest.renderer), manifest.actions["idle"] != nil, !manifest.name.isEmpty, manifest.name.count <= 60, !manifest.license.isEmpty, manifest.actions.count <= 30 else { throw QWhaleMaidenError.message("素材格式或 idle 动作缺失") }
        for (_,action) in manifest.actions {
            guard Self.safeRelative(action.file) else { throw QWhaleMaidenError.message("素材路径不安全") }
            let file = directory.appendingPathComponent(action.file)
            guard file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw QWhaleMaidenError.message("素材路径越界") }
            if manifest.renderer == "svg" {
                guard file.pathExtension.lowercased() == "svg" else { throw QWhaleMaidenError.message("SVG 包的动作必须是 svg 文件") }
                try SVGGuard.validate(Data(contentsOf:file))
            } else {
                guard ["png","webp"].contains(file.pathExtension.lowercased()), let src = CGImageSourceCreateWithURL(file as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [CFString:Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width <= 4096, height <= 4096 else { throw QWhaleMaidenError.message("精灵图格式或尺寸超出预算") }
                let fw = action.frameWidth ?? 0, fh = action.frameHeight ?? 0, frames = action.frames ?? 0, fps = action.fps ?? 0
                guard fw > 0, fh > 0, frames > 0, frames <= 512, fps.isFinite, fps > 0, fps <= 60, width % fw == 0, height % fh == 0, frames <= (width/fw)*(height/fh) else { throw QWhaleMaidenError.message("精灵图帧参数不正确") }
            }
        }
        return manifest
    }
    private func command(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/unzip"); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 1024*1024 else { throw QWhaleMaidenError.message("无法读取 ZIP 素材包") }
        return String(data:data,encoding:.utf8) ?? ""
    }
    func install(_ source: URL) throws -> InstalledPack {
        let fm = FileManager.default; let staging = root.appendingPathComponent(".import-"+UUID().uuidString)
        defer { try? fm.removeItem(at:staging) }
        if source.pathExtension.lowercased() == "zip" {
            let size = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 50*1024*1024 else { throw QWhaleMaidenError.message("压缩包超过 50 MiB") }
            let names = try command(["-Z1",source.path]).split(separator:"\n").map(String.init)
            guard names.count <= 512, names.allSatisfy({ Self.safeRelative($0.hasSuffix("/") ? String($0.dropLast()) : $0) }) else { throw QWhaleMaidenError.message("ZIP 含不安全路径或文件过多") }
            let metadata = try command(["-Z","-l",source.path])
            var declaredSize = 0
            for line in metadata.split(separator:"\n") {
                let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let first = columns.first, first.count == 10 {
                    guard first.first == "-" || first.first == "d" else { throw QWhaleMaidenError.message("ZIP 不允许链接或特殊文件") }
                    guard columns.count > 3, let bytes = Int(columns[3]), bytes >= 0 else { throw QWhaleMaidenError.message("ZIP 大小字段不正确") }; declaredSize += bytes
                }
            }
            guard declaredSize > 0, declaredSize <= 200*1024*1024 else { throw QWhaleMaidenError.message("ZIP 解包大小超出预算") }
            try fm.createDirectory(at:staging,withIntermediateDirectories:true)
            _ = try command(["-q",source.path,"-d",staging.path])
        } else { _ = try validate(directory:source); try fm.copyItem(at:source,to:staging) }
        var packDirectory = staging
        if !fm.fileExists(atPath:staging.appendingPathComponent("manifest.json").path) {
            let dirs = try fm.contentsOfDirectory(at:staging,includingPropertiesForKeys:[.isDirectoryKey]).filter { !$0.lastPathComponent.hasPrefix(".") }
            guard dirs.count == 1 else { throw QWhaleMaidenError.message("包根目录需要 manifest.json") }; packDirectory = dirs[0]
        }
        let manifest = try validate(directory:packDirectory); let id = UUID().uuidString
        try fm.moveItem(at:packDirectory,to:root.appendingPathComponent(id))
        return InstalledPack(id:id,manifest:manifest)
    }
    func assetURL(packID: String, relative: String) -> URL? {
        guard UUID(uuidString:packID) != nil, Self.safeRelative(relative) else { return nil }
        let directory = root.appendingPathComponent(packID)
        let file = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path+"/") else { return nil }; return file
    }
}

final class AssetScheme: NSObject, WKURLSchemeHandler {
    let packs: AssetPackManager
    init(packs: AssetPackManager) { self.packs = packs }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator:"/")
        guard url.host == "local", parts.count >= 2, let file = packs.assetURL(packID:String(parts[0]), relative:parts.dropFirst().joined(separator:"/")), let data = try? Data(contentsOf:file), data.count <= 32*1024*1024 else { task.didFailWithError(QWhaleMaidenError.message("素材不可用")); return }
        let mime = ["svg":"image/svg+xml","png":"image/png","webp":"image/webp"][file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(URLResponse(url:url,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil)); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
