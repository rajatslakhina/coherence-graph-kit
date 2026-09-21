// Saturating.swift
//
// Every arithmetic operation in this package that could trap goes through this
// file. Swift's `+`, `*`, `/` and `%` all trap on overflow or division by zero,
// and `Int.min / -1` traps even though both operands look harmless. A reactive
// graph recomputes derived values from data it does not control, so a trapping
// operator inside a recompute closure is a crash the host app cannot catch.
//
// The choice is saturation rather than wrapping (`&+`): wrapping turns a
// too-large total into a negative one, which is a silent correctness bug that
// renders as a plausible number. Saturation clamps to a value that is obviously
// wrong at the edge, and is therefore visible.

/// Guarded integer arithmetic that clamps instead of trapping.
public enum Saturating {

    /// `a + b`, clamped to `Int.min ... Int.max` instead of trapping.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, clamped to `Int.min ... Int.max` instead of trapping.
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to `Int.min ... Int.max` instead of trapping.
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        // The sign of the unrepresentable product decides which end to clamp to.
        let negative = (a < 0) != (b < 0)
        return negative ? Int.min : Int.max
    }

    /// `a / b`. Returns `fallback` when `b == 0`, and clamps the single
    /// overflowing division case (`Int.min / -1`) to `Int.max`.
    public static func divide(_ a: Int, _ b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        let (result, overflow) = a.dividedReportingOverflow(by: b)
        guard overflow else { return result }
        return Int.max
    }

    /// `a % b`. Returns `fallback` when `b == 0`, and returns 0 for the single
    /// overflowing remainder case (`Int.min % -1`), which is mathematically 0.
    public static func remainder(_ a: Int, _ b: Int, fallback: Int = 0) -> Int {
        guard b != 0 else { return fallback }
        let (result, overflow) = a.remainderReportingOverflow(dividingBy: b)
        guard overflow else { return result }
        // The only overflowing case is `Int.min % -1`, whose true value is 0.
        return 0
    }
}
