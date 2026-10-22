import Foundation

/// Confronto tra numeri di versione ("2.10.1" è più recente di "2.9").
public enum Versions {
    /// I numeri della versione, ignorando lettere e separatori ("1.2b3" → [1, 2, 3]).
    public static func parts(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// true se `a` è più recente di `b`.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
