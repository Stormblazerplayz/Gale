import Foundation

/// Fractional order keys (the same scheme as the "fractional-indexing" npm package by rocicorp).
///
/// Every ordered thing (layers, frames, strokes, tracks) has a `key` string. Sorting by key
/// (plain byte order) gives the order. A new key can always be made between two others, so
/// inserting or moving one item never changes the keys of the rest. That keeps live sync small
/// and lets two devices insert at the same time without fighting.
public enum OrderKey {
    static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let zero: Character = "0"
    static let smallestInteger = "A" + String(repeating: "0", count: 26)
    public static let first = "a0"

    static func index(_ c: Character) -> Int? {
        guard let a = c.asciiValue else { return nil }
        switch a {
        case 48...57: return Int(a) - 48           // 0-9
        case 65...90: return Int(a) - 65 + 10      // A-Z
        case 97...122: return Int(a) - 97 + 36     // a-z
        default: return nil
        }
    }

    /// The key between `a` and `b`. Pass nil for "start" or "end". `a` must sort before `b`.
    /// Returns nil only if the keys are broken or not in order.
    public static func between(_ a: String?, _ b: String?) -> String? {
        if let a = a, !isValid(a) { return nil }
        if let b = b, !isValid(b) { return nil }
        if let a = a, let b = b, a >= b { return nil }

        switch (a, b) {
        case (nil, nil):
            return first
        case (nil, let b?):
            guard let ib = integerPart(b) else { return nil }
            let fb = String(b.dropFirst(ib.count))
            if ib == smallestInteger {
                guard let m = midpoint("", fb) else { return nil }
                return ib + m
            }
            if ib < b { return ib }
            return decrementInteger(ib)
        case (let a?, nil):
            guard let ia = integerPart(a) else { return nil }
            let fa = String(a.dropFirst(ia.count))
            if let i = incrementInteger(ia) { return i }
            guard let m = midpoint(fa, nil) else { return nil }
            return ia + m
        case (let a?, let b?):
            guard let ia = integerPart(a), let ib = integerPart(b) else { return nil }
            let fa = String(a.dropFirst(ia.count))
            let fb = String(b.dropFirst(ib.count))
            if ia == ib {
                guard let m = midpoint(fa, fb) else { return nil }
                return ia + m
            }
            if let i = incrementInteger(ia), i < b { return i }
            guard let m = midpoint(fa, nil) else { return nil }
            return ia + m
        }
    }

    /// `count` keys in order, all after `a` (nil = from the start) and before `b` (nil = to the end).
    public static func keys(between a: String?, and b: String?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var out: [String] = []
        var last = a
        if b == nil {
            for _ in 0..<count {
                guard let k = between(last, nil) else { break }
                out.append(k)
                last = k
            }
            return out
        }
        // Between two keys: split the gap in half again and again.
        if count == 1 {
            if let k = between(a, b) { out.append(k) }
            return out
        }
        guard let mid = between(a, b) else { return [] }
        let left = keys(between: a, and: mid, count: count / 2)
        let right = keys(between: mid, and: b, count: count - count / 2 - 1)
        return left + [mid] + right
    }

    public static func isValid(_ key: String) -> Bool {
        guard let ip = integerPart(key) else { return false }
        if key == smallestInteger { return false }
        let frac = key.dropFirst(ip.count)
        if frac.last == zero { return false }
        return key.allSatisfy { index($0) != nil }
    }

    static func integerLength(_ head: Character) -> Int? {
        guard let a = head.asciiValue else { return nil }
        if a >= 97 && a <= 122 { return Int(a) - 97 + 2 }
        if a >= 65 && a <= 90 { return 90 - Int(a) + 2 }
        return nil
    }

    static func integerPart(_ key: String) -> String? {
        guard let head = key.first, let n = integerLength(head), key.count >= n else { return nil }
        return String(key.prefix(n))
    }

    static func incrementInteger(_ x: String) -> String? {
        let head = x.first!
        var digs = Array(x.dropFirst())
        var carry = true
        var i = digs.count - 1
        while carry && i >= 0 {
            let d = (index(digs[i]) ?? 0) + 1
            if d == digits.count {
                digs[i] = zero
            } else {
                digs[i] = digits[d]
                carry = false
            }
            i -= 1
        }
        if carry {
            if head == "Z" { return "a" + String(zero) }
            if head == "z" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! + 1))
            if h > "a" {
                digs.append(zero)
            } else {
                digs.removeLast()
            }
            return String(h) + String(digs)
        }
        return String(head) + String(digs)
    }

    static func decrementInteger(_ x: String) -> String? {
        let head = x.first!
        var digs = Array(x.dropFirst())
        var borrow = true
        var i = digs.count - 1
        while borrow && i >= 0 {
            let d = (index(digs[i]) ?? 0) - 1
            if d == -1 {
                digs[i] = digits[digits.count - 1]
            } else {
                digs[i] = digits[d]
                borrow = false
            }
            i -= 1
        }
        if borrow {
            if head == "a" { return "Z" + String(digits[digits.count - 1]) }
            if head == "A" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! - 1))
            if h < "Z" {
                digs.append(digits[digits.count - 1])
            } else {
                digs.removeLast()
            }
            return String(h) + String(digs)
        }
        return String(head) + String(digs)
    }

    /// The fractional part between a and b (b nil = no upper bound). Neither may end in "0".
    static func midpoint(_ a: String, _ b: String?) -> String? {
        if let b = b {
            if a >= b { return nil }
            // Common prefix (a is padded with zeros).
            let aa = Array(a), bb = Array(b)
            var n = 0
            while n < bb.count && (n < aa.count ? aa[n] : zero) == bb[n] { n += 1 }
            if n > 0 {
                let restA = n < aa.count ? String(aa[n...]) : ""
                guard let m = midpoint(restA, String(bb[n...])) else { return nil }
                return String(bb[0..<n]) + m
            }
        }
        let digitA = a.first.flatMap { index($0) } ?? 0
        let digitB = b.flatMap { $0.first }.flatMap { index($0) } ?? digits.count
        if digitB - digitA > 1 {
            let mid = Int((Double(digitA + digitB) * 0.5).rounded())
            return String(digits[mid])
        }
        if let b = b, b.count > 1 {
            return String(b.first!)
        }
        guard let rest = midpoint(String(a.dropFirst()), nil) else { return nil }
        return String(digits[digitA]) + rest
    }
}
