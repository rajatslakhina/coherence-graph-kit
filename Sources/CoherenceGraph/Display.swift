// Display.swift
//
// Pure formatting and input-clamping helpers.
//
// These live in the core module rather than next to the SwiftUI view that uses
// them, for one reason: `CoherenceGraphUI` is entirely inside
// `#if canImport(SwiftUI)`, so nothing compiles it on Linux and the test suite
// cannot reach it. Two functions whose whole purpose is surviving hostile input
// — a `Double` that might be NaN, an `Int` that might be `Int.min` — were
// therefore the least-tested code in the package. Moving them here makes them
// ordinary, testable Swift.

/// Formats integer cents for display.
public enum Money {

    /// Renders `cents` as a currency-ish string, preserving sign, without
    /// trapping on any `Int` input including `Int.min`.
    ///
    /// `abs(Int.min)` traps, and `Int` division truncates toward zero, so
    /// `-50 / 100 == 0` — which is how a naive implementation renders minus
    /// fifty cents as `$0.50`. The sign is therefore taken from the input, not
    /// from the quotient.
    public static func format(cents: Int) -> String {
        let negative = cents < 0
        let dollars = Saturating.divide(cents, 100)
        let rawRemainder = Saturating.remainder(cents, 100)
        // Magnitude via the guarded helper: `abs` and unary minus both trap on
        // `Int.min`, and `Int.min % 100` is a legitimate negative value here.
        let dollarsMagnitude = dollars < 0 ? Saturating.subtract(0, dollars) : dollars
        let centsMagnitude = rawRemainder < 0 ? Saturating.subtract(0, rawRemainder) : rawRemainder
        let padding = centsMagnitude < 10 ? "0" : ""
        return "\(negative ? "-" : "")$\(dollarsMagnitude).\(padding)\(centsMagnitude)"
    }
}

/// Clamps continuous UI input to a discrete, in-range quantity.
public enum Quantity {

    /// Converts a slider position to an integer quantity inside `bounds`.
    ///
    /// `Int(someDouble)` traps on NaN, on infinity, and on anything outside
    /// `Int`'s range. A slider bound to a small range should never produce
    /// those, but "should never" is not something the runtime enforces, and
    /// this converts a value the caller did not compute itself.
    public static func fromSlider(_ value: Double, bounds: ClosedRange<Int>) -> Int {
        // NaN first and explicitly: every comparison against NaN is false, so
        // it would otherwise fall through both clamps and reach `Int(_:)`,
        // which traps on it.
        guard !value.isNaN else { return bounds.lowerBound }
        // Comparing before rounding means each infinity clamps to the end it
        // actually points at, rather than both collapsing to the lower bound.
        if value <= Double(bounds.lowerBound) { return bounds.lowerBound }
        if value >= Double(bounds.upperBound) { return bounds.upperBound }
        // Strictly inside two `Int`-representable bounds, so this conversion
        // cannot be out of range.
        return Int(value.rounded())
    }
}
