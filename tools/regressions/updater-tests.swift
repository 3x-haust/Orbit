import Foundation
import Security
@testable import Orbit

@main struct UpdaterTests {
    static func main() throws {
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func release(_ version: String, draft: Bool = false, prerelease: Bool = false,
                     asset: Bool = true) -> [String: Any] {
            ["tag_name": "v\(version)", "body": "Notes \(version)",
             "html_url": "https://github.com/3x-haust/Orbit/releases/tag/v\(version)",
             "draft": draft, "prerelease": prerelease,
             "assets": asset ? [["name": "Orbit-\(version).zip", "size": 123,
                                  "browser_download_url": "https://github.com/3x-haust/Orbit/releases/download/v\(version)/Orbit-\(version).zip"]] : []]
        }
        func parse(_ entries: [[String: Any]]) throws -> Updater.Release {
            try Updater.parse(JSONSerialization.data(withJSONObject: entries))
        }
        do {
            let found = try parse([release("1.7.1"), release("1.7.2"), release("1.7.0"),
                                   release("9.0.0", draft: true), release("8.0.0", prerelease: true)])
            check(found.version == "1.7.2", "the bridge finds the new-ID release even while GitHub latest stays on the bridge")
            check(found.asset.lastPathComponent == "Orbit-1.7.2.zip", "the selected ZIP belongs to the selected version")
            check(found.notes == "Notes 1.7.2" && found.size == 123, "release notes and download size follow the selected version")
        } catch {
            check(false, "the published release list is readable: \(error)")
        }
        do {
            let found = try parse([release("1.9.0"), release("1.10.0"), release("1.7.2")])
            check(found.version == "1.10.0", "updates compare numeric versions rather than release order or text")
        } catch { check(false, "numeric release selection: \(error)") }
        for entries in [[], [release("2.0.0", draft: true), release("3.0.0", prerelease: true)]] {
            do { _ = try parse(entries); check(false, "an empty stable feed reports no releases") }
            catch Updater.FetchError.noReleases { check(true, "an empty stable feed reports no releases") }
            catch { check(false, "empty stable feed returned the wrong error: \(error)") }
        }
        do { _ = try parse([release("1.7.2", asset: false)]); check(false, "a release without a ZIP is rejected") }
        catch Updater.FetchError.noAsset { check(true, "a release without a ZIP is rejected") }
        catch { check(false, "missing asset returned the wrong error: \(error)") }

        if CommandLine.arguments.count == 3 {
            let old = URL(fileURLWithPath: CommandLine.arguments[1])
            let new = URL(fileURLWithPath: CommandLine.arguments[2])
            check(!Updater.signedByUs(old), "the new update path refuses the legacy bundle ID")
            check(Updater.signedByUs(new), "the new update path accepts the new bundle ID signed by Orbit's team")
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let created = SecStaticCodeCreateWithPath(new as CFURL, [], &code) == errSecSuccess
                && SecRequirementCreateWithString(FanHelper.clientRequirement as CFString, [], &requirement) == errSecSuccess
            let accepted = created && code != nil && requirement != nil
                && SecStaticCodeCheckValidity(code!, [], requirement) == errSecSuccess
            check(accepted, "the fan helper accepts the new-ID Orbit client")
        }
        print("\(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
