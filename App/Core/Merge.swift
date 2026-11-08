import Foundation

/// Drei-Wege-Zusammenführung zeilenweise (wie `diff3`): Basis = letzter gemeinsamer Stand, dazu die eigene und die
/// Server-Fassung. Gibt `nil` zurück, wenn beide dieselbe Stelle verschieden geändert haben – dann legt der Sync eine
/// Konfliktkopie an statt etwas zu verlieren.
nonisolated enum Merge3 {
    static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs { return mine }
        if mine == base { return theirs }
        if theirs == base { return mine }
        let b = base.components(separatedBy: "\n"), m = mine.components(separatedBy: "\n"), t = theirs.components(separatedBy: "\n")
        guard b.count * max(m.count, t.count) < 4_000_000 else { return nil }   // sehr große Notizen: lieber Kopie
        let mm = matches(b, m), tm = matches(b, t)
        // Ankerzeilen: in beiden Fassungen unverändert vorhanden
        var anchors: [(Int, Int, Int)] = [(-1, -1, -1)]
        for i in b.indices { if let x = mm[i], let y = tm[i] { anchors.append((i, x, y)) } }
        anchors.append((b.count, m.count, t.count))
        var out: [String] = []
        for k in 1..<anchors.count {
            let (pb, pm, pt) = anchors[k - 1], (nb, nm, nt) = anchors[k]
            let cb = Array(b[(pb + 1)..<nb]), cm = Array(m[(pm + 1)..<nm]), ct = Array(t[(pt + 1)..<nt])
            if cm == cb { out += ct }
            else if ct == cb { out += cm }
            else if cm == ct { out += cm }
            else { return nil }
            if nb < b.count { out.append(b[nb]) }
        }
        return out.joined(separator: "\n")
    }

    /// Längste gemeinsame Teilfolge: Index in `a` → Index in `b`.
    static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        let n = a.count, m = b.count
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var res = [Int?](repeating: nil, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { res[i] = j; i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return res
    }
}

/// Lokaler Volltextindex: Wörter ohne Groß-/Kleinschreibung und Akzente; Suche nach Wortanfängen (alle Wörter müssen passen).
nonisolated struct SearchIndex {
    private var words: [Int: Set<String>] = [:]
    private var titles: [Int: Set<String>] = [:]

    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    mutating func update(id: Int, title: String, text: String) {
        titles[id] = Set(Self.tokens(title))
        words[id] = Set(Self.tokens(title + " " + text))
    }

    mutating func remove(_ id: Int) { words[id] = nil; titles[id] = nil }
    mutating func removeAll() { words = [:]; titles = [:] }

    /// Treffer mit Rang (2 = alle Wörter im Titel, 1 = im Text).
    func search(_ query: String) -> [Int: Int] {
        let q = Self.tokens(query)
        guard !q.isEmpty else { return [:] }
        var out: [Int: Int] = [:]
        for (id, w) in words where q.allSatisfy({ t in w.contains { $0.hasPrefix(t) } }) {
            let tw = titles[id] ?? []
            out[id] = q.allSatisfy({ t in tw.contains { $0.hasPrefix(t) } }) ? 2 : 1
        }
        return out
    }
}
