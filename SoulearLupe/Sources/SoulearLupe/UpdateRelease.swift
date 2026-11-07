import Foundation

struct AppVersion: Comparable {
    let parts: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count else { return nil }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let state: String
    }
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func downloadURL(repository: String) -> URL? {
        guard !draft, !prerelease, AppVersion(tag_name) != nil else { return nil }
        return assets.first {
            let url = $0.browser_download_url
            return $0.name == "MR-Linse-macOS-arm64.zip" && $0.size > 0 && $0.state == "uploaded"
                && url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
                && url.path.hasPrefix("/\(repository)/releases/download/\(tag_name)/")
        }?.browser_download_url
    }

    static func validRepository(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }
}
