/// Type-a-few-letters matching for window search: the query's letters must
/// appear in order in one of an item's fields (app name, title).
public enum WindowSearch {
    /// Higher is better; nil when nothing matches. An empty query matches everything with 0.
    public static func score(_ query: String, in fields: [String]) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        return fields.compactMap { score(q, field: Array($0.lowercased())) }.max()
    }

    /// Items that match, best first. Ties keep their given order (most recent first).
    public static func rank<T>(_ query: String, items: [T], fields: (T) -> [String]) -> [T] {
        items.enumerated()
            .compactMap { i, item in score(query, in: fields(item)).map { (i, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    /// Greedy left-to-right match. Rewards a prefix, word starts and runs of
    /// adjacent letters; letters far apart earn less.
    private static func score(_ q: [Character], field f: [Character]) -> Int? {
        var score = 0
        var last = -1
        var qi = 0
        for (fi, c) in f.enumerated() where qi < q.count {
            guard c == q[qi] else { continue }
            var s = 1
            if fi == 0 { s += 8 }
            else if !f[fi - 1].isLetter && !f[fi - 1].isNumber { s += 6 }
            if last >= 0 && fi == last + 1 { s += 4 }
            score += s
            last = fi
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}
