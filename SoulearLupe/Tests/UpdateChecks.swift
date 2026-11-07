import Foundation

@main enum UpdateChecks {
    static func main() throws {
        assert(AppVersion("v0.2.0") == AppVersion("0.2"))
        assert(AppVersion("0.10.0")! > AppVersion("0.9.0")!)
        assert(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        for value in ["v1.0.0-beta", "1..0", "1.2.3.4", "1", "-1.2.0", "1.2.x"] { assert(AppVersion(value) == nil) }
        assert(GitHubRelease.validRepository("martin/MR-Linse"))
        for value in ["", "https://github.com/a/b", "a/b/c", "a/b?x=y", "../repo"] { assert(!GitHubRelease.validRepository(value)) }
        let fixture = #"{"tag_name":"v0.3.0","body":"Neue Kameras","draft":false,"prerelease":false,"assets":[{"name":"MR-Linse-macOS-arm64.zip","browser_download_url":"https://github.com/martin/MR-Linse/releases/download/v0.3.0/MR-Linse-macOS-arm64.zip","size":100,"state":"uploaded"}]}"#
        func decode(_ json: String) throws -> GitHubRelease { try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8)) }
        let release = try decode(fixture)
        assert(release.downloadURL(repository: "martin/MR-Linse") != nil)
        assert(release.downloadURL(repository: "other/repo") == nil)
        for bad in [fixture.replacingOccurrences(of: "https://github.com", with: "http://github.com"), fixture.replacingOccurrences(of: "https://github.com", with: "https://example.org"), fixture.replacingOccurrences(of: "\"size\":100", with: "\"size\":0"), fixture.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true"), fixture.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true"), fixture.replacingOccurrences(of: "uploaded", with: "starter"), fixture.replacingOccurrences(of: "macOS-arm64.zip", with: "Windows.zip")] {
            let invalid = try decode(bad)
            assert(invalid.downloadURL(repository: "martin/MR-Linse") == nil)
        }
        print("Update checks passed: versions, repository, release selection and download URLs")
    }
}
