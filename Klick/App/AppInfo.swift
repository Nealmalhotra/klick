import Foundation

enum AppInfo {
    static let name = "Klick"
    static let tagline = "A radial shortcut wheel for your files."
    static let author = "Giovanni D'Andrea"
    /// Public repository.
    static let repositoryURL = URL(string: "https://github.com/imggion/klick")!
    static var issuesURL: URL { repositoryURL.appendingPathComponent("issues") }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    struct Contributor: Identifiable {
        let name: String
        let role: String
        var url: URL?
        var id: String { name }
    }

    /// Add yourself here when you contribute ✨
    static let contributors: [Contributor] = [
        Contributor(name: "Giovanni D'Andrea", role: "Creator & maintainer"),
    ]

    struct Acknowledgement: Identifiable {
        let name: String
        let detail: String
        let license: String
        let url: URL
        /// Bundled license text (`<name>.txt` in Resources).
        let licenseFile: String
        var id: String { name }
    }

    static let acknowledgements: [Acknowledgement] = [
        Acknowledgement(
            name: "libwebp",
            detail: "WebP encoding, by Google",
            license: "BSD-3-Clause",
            url: URL(string: "https://chromium.googlesource.com/webm/libwebp")!,
            licenseFile: "libwebp-COPYING"
        ),
        Acknowledgement(
            name: "LAME",
            detail: "MP3 encoding (dynamically linked)",
            license: "LGPL-2.0",
            url: URL(string: "https://lame.sourceforge.io")!,
            licenseFile: "lame-COPYING"
        ),
    ]
}
