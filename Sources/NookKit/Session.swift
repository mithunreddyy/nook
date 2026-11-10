/// A window as saved in a session or workspace: its ID this login, its app,
/// and a fingerprint of its title (never the title itself).
public struct SavedWindow: Codable, Hashable, Sendable {
    public var id: UInt32
    public var app: String
    public var title: String
    /// Its tile was a split stack (every window showing).
    public var split: Bool?
    /// It was pinned to its tile's place.
    public var pinned: Bool?

    public init(id: UInt32, app: String, title: String, split: Bool? = nil, pinned: Bool? = nil) {
        self.id = id
        self.app = app
        self.title = title
        self.split = split
        self.pinned = pinned
    }

    /// Puts back split stacks and pins after `arrange`, from the saved windows each live one matched.
    public static func restoreExtras(_ model: inout ScreenModel, saved: [[SavedWindow]], slots: [UInt32: Int]) {
        for (w, slot) in slots where saved.indices.contains(slot) {
            guard let t = model.tileIndex(of: w) else { continue }
            if saved[slot].contains(where: { $0.split == true }) { model.setSplit(tile: t, true) }
            if saved[slot].contains(where: { $0.pinned == true }) && model.tiles[t].showing == w { model.pin(w) }
        }
    }

    /// Gives live windows the slot (tile index) of the saved window they match.
    /// Passes, best first: same window ID (same login), same app and title,
    /// then any saved window of the same app. Each saved window matches once.
    public static func match(saved: [[SavedWindow]], live: [SavedWindow]) -> [UInt32: Int] {
        var pool: [(ref: SavedWindow, slot: Int)] = saved.enumerated().flatMap { slot, refs in refs.map { ($0, slot) } }
        var out: [UInt32: Int] = [:]
        let passes: [(SavedWindow, SavedWindow) -> Bool] = [
            { $0.id == $1.id && $0.app == $1.app },
            { $0.app == $1.app && $0.title == $1.title },
            { $0.app == $1.app },
        ]
        for same in passes {
            for w in live where out[w.id] == nil {
                if let i = pool.firstIndex(where: { same($0.ref, w) }) {
                    out[w.id] = pool[i].slot
                    pool.remove(at: i)
                }
            }
        }
        return out
    }
}

/// A short, stable fingerprint (64-bit FNV-1a) so titles can be matched without being stored.
public enum Fingerprint {
    public static func of(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

public enum Version {
    /// True when `a` is a later version than `b` ("1.10" > "1.9", "v2" > "1.5").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingPrefix("v").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
