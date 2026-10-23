import Foundation

@main struct AssetTests {
    static var count=0
    static func check(_ condition: Bool,_ text: String) { precondition(condition,text);count+=1;print("PASS: "+text) }
    static func rejects(_ text: String,_ work: () throws -> Void) { do { try work();fatalError("Expected rejection: "+text) } catch { count+=1;print("PASS: "+text) } }
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("starbud-assets-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let manager=try AssetPackManager(root:root.appendingPathComponent("installed"))
        let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/example-pack")
        let pack=try manager.install(source)
        check(pack.manifest.name == "星环小团","valid folder pack imports")
        check(manager.list().count == 1,"installed manifest remains readable")
        check(manager.assetURL(packID:pack.id,relative:"../outside") == nil,"asset path traversal rejected")
        rejects("SVG script rejected") { try SVGGuard.validate(Data("<svg><script>alert(1)</script></svg>".utf8)) }
        rejects("SVG external href rejected") { try SVGGuard.validate(Data("<svg><image href='https://example.com/x.png'/></svg>".utf8)) }
        rejects("mixed local/external CSS URLs rejected") { try SVGGuard.validate(Data("<svg><path style='fill:url(#ok);filter:url(https://example.com/x)'/></svg>".utf8)) }
        rejects("SVG external entity rejected") { try SVGGuard.validate(Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>".utf8)) }
        let bad=root.appendingPathComponent("bad");try FileManager.default.copyItem(at:source,to:bad)
        try FileManager.default.createSymbolicLink(at:bad.appendingPathComponent("escape.svg"),withDestinationURL:URL(fileURLWithPath:"/etc/passwd"))
        rejects("symlink in folder pack rejected") { _ = try manager.install(bad) }
        let archive=root.appendingPathComponent("valid.zip")
        let zip=Process();zip.executableURL=URL(fileURLWithPath:"/usr/bin/zip");zip.currentDirectoryURL=source;zip.arguments=["-q",archive.path,"manifest.json","idle.svg","wait.svg"];try zip.run();zip.waitUntilExit();check(zip.terminationStatus == 0,"test ZIP produced")
        let zipped=try manager.install(archive);check(zipped.manifest.renderer == "svg","valid ZIP pack imports")
        check(manager.list().count == 2,"failed imports preserve active installed packs")
        print("\(count) asset checks passed")
    }
}
