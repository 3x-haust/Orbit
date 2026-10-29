// Fetches Tavi's latest release into tools/tavi-cache, checked the same way Orbit's updater checks it:
// GitHub's SHA-256 digest, the maintainer's Ed25519 signature, and the code signature.
// Usage: swift tools/fetch-tavi.swift <cache dir>
import CryptoKit
import Foundation

let publicKey = Data(base64Encoded: "k6crVb3PuDp1IXIJMFq7CmoR9SXKo6JaV15oivGtEOM=")!
let cache = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/tavi-cache")

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("fetch-tavi: \(message)\n".utf8)); exit(1) }

func get(_ url: URL) -> Data {
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("Orbit-build", forHTTPHeaderField: "User-Agent")
    let done = DispatchSemaphore(value: 0)
    var result: Data?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
        done.signal()
    }.resume()
    done.wait()
    guard let result else { fail("couldn't download \(url)") }
    return result
}

func run(_ tool: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

let latest = get(URL(string: "https://api.github.com/repos/3x-haust/tavi/releases/latest")!)
guard let json = try? JSONSerialization.jsonObject(with: latest) as? [String: Any], let tag = json["tag_name"] as? String,
      let assets = json["assets"] as? [[String: Any]] else { fail("unexpected release response") }
let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
func asset(_ name: String) -> [String: Any]? { assets.first { $0["name"] as? String == name } }
guard let zip = asset("Tavi-\(version).zip"), let sig = asset("Tavi-\(version).zip.sig"),
      let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)),
      let sigURL = (sig["browser_download_url"] as? String).flatMap(URL.init(string:)),
      let digest = zip["digest"] as? String, digest.hasPrefix("sha256:") else { fail("release \(version) has no signed archive") }

let archive = get(zipURL), signature = get(sigURL)
guard SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == digest.dropFirst(7).lowercased() else { fail("checksum mismatch") }
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(signature, for: archive) else { fail("bad signature") }

let work = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-tavi-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let zipFile = work.appendingPathComponent("Tavi.zip")
try! archive.write(to: zipFile)
guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path]) else { fail("couldn't unpack") }
let app = work.appendingPathComponent("Tavi.app")
guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { fail("code signature invalid") }
let helper = app.appendingPathComponent("Contents/Helpers/TaviInputMethod.app")
guard let info = NSDictionary(contentsOf: helper.appendingPathComponent("Contents/Info.plist")),
      info["CFBundleIdentifier"] as? String == "dev.3xhaust.inputmethod.tavi",
      info["CFBundleShortVersionString"] as? String == version else { fail("unexpected bundle inside the archive") }

try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
let dest = cache.appendingPathComponent("TaviInputMethod.app")
try? FileManager.default.removeItem(at: dest)
try! FileManager.default.moveItem(at: helper, to: dest)
try? FileManager.default.removeItem(at: work)
print("Tavi \(version) → \(dest.path)")
