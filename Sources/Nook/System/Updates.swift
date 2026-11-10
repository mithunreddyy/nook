import AppKit
import NookKit

/// Asks GitHub for the newest Nook release, once a day when allowed or when
/// asked. Sends nothing about the Mac or its windows.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    struct Release: Equatable {
        var version: String
        var url: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    @Published private(set) var state: State = .idle
    private var timer: Timer?
    private var announced: String?

    static let api = URL(string: "https://api.github.com/repos/mithunreddyy/nook/releases/latest")!

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
    }

    func checkIfDue() {
        let prefs = Preferences.shared
        guard prefs.checkForUpdates else { return }
        if let last = prefs.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard state != .checking else { return }
        state = .checking
        Preferences.shared.lastUpdateCheck = Date()
        var request = URLRequest(url: Self.api, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var release: Release?
            if let data, status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String,
               let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page)
            }
            let failure = error?.localizedDescription ?? (status == 404 ? "No releases published yet" : "GitHub answered \(status)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Updates.shared.finish(release, failure: failure, manual: manual) }
            }
        }.resume()
    }

    private func finish(_ release: Release?, failure: String, manual: Bool) {
        guard let release else {
            state = .failed(failure)
            return
        }
        let current = Bundle.main.version
        if Version.isNewer(release.version, than: current) {
            state = .available(release)
            if !manual, announced != release.version {
                announced = release.version
                Toast.show("Nook \(release.version) is out · Settings → General", on: Engine.shared.currentDisplay, symbol: "arrow.down.circle")
            }
        } else {
            state = .upToDate
        }
    }
}
