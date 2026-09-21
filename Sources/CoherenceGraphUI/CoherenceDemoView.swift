#if canImport(SwiftUI)
import SwiftUI
import CoherenceGraph

/// Side-by-side proof that the glitch is real and that this package removes it.
///
/// Change the quantity. The left column is a depth-first push propagator — the
/// shape a hand-rolled observable layer converges on — and it publishes two
/// states for one write, the first of which describes a cart that never
/// existed. The right column is `CoherenceEngine` and publishes one.
@MainActor
public struct CoherenceDemoView: View {

    @State private var model: CoherenceDemoModel

    /// - Parameter policy: supplied by the host app, which owns the
    ///   compiled-in configuration this view runs under.
    public init(policy: CoherencePolicy) {
        _model = State(initialValue: CoherenceDemoModel(policy: policy))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    thesis
                    quantityControl
                    comparison
                    ownership
                    auditSection
                }
                .padding(20)
            }
            .navigationTitle("Coherence")
        }
    }

    // MARK: - Sections

    private var thesis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("One write. Two propagators.")
                .font(.title3.weight(.semibold))
            Text(
                "A diamond — cart feeds subtotal and tax, both feed total — is the "
                + "smallest graph where update order is observable. Depth-first push "
                + "publishes a state where the two branches disagree about which cart "
                + "they came from."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var quantityControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quantity")
                    .font(.headline)
                Spacer()
                Text("\(model.cart)")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 12) {
                Button {
                    model.decrement()
                } label: {
                    Label("Decrease", systemImage: "minus.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.cart <= 0)

                Slider(
                    value: Binding(
                        get: { Double(model.cart) },
                        set: { model.setCart(Self.quantity(fromSlider: $0)) }
                    ),
                    in: 0...99,
                    step: 1
                )
                .accessibilityLabel("Quantity")

                Button {
                    model.increment()
                } label: {
                    Label("Increase", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.cart >= 99)
            }
        }
    }

    private var comparison: some View {
        VStack(spacing: 14) {
            panel(
                title: "Depth-first push",
                subtitle: "NaivePropagator",
                states: model.lastWriteNaive,
                accent: .red
            )
            panel(
                title: "Ordered commit",
                subtitle: "CoherenceEngine",
                states: model.lastWriteCoherent,
                accent: .green
            )
        }
    }

    private func panel(
        title: String,
        subtitle: String,
        states: [GraphState],
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(states.count) state\(states.count == 1 ? "" : "s") published")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(accent)
            }

            if states.isEmpty {
                Text("No write yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(states.enumerated()), id: \.offset) { pair in
                        stateRow(index: pair.offset, observation: pair.element)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stateRow(index: Int, observation: GraphState) -> some View {
        let incoherent = !observation.isCoherent
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if incoherent {
                    Label("cart never had this state", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            HStack {
                amount("subtotal", observation.subtotal)
                Spacer()
                amount("tax", observation.tax)
                Spacer()
                amount("total", observation.total)
            }
        }
        .padding(10)
        .background(
            (incoherent ? Color.red.opacity(0.12) : Color.green.opacity(0.10)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func amount(_ label: String, _ cents: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.money(cents))
                .font(.subheadline.monospacedDigit().weight(.medium))
        }
    }

    private var ownership: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Single-writer ownership")
                .font(.headline)
            Text(
                "The cart domain is owned by SwiftUI. A write attributed to the "
                + "legacy UIKit stack is refused, so \"two sources of truth\" is a "
                + "compile-time-shaped error rather than a convention."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Attempt a write from the legacy stack") {
                model.attemptRogueWrite()
            }
            .buttonStyle(.bordered)
            if let error = model.lastError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Executed invariants")
                    .font(.headline)
                Spacer()
                Text(model.auditIsHealthy ? "healthy" : "check failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.auditIsHealthy ? .green : .red)
            }
            Text(
                "These are run, not asserted in a README. The NaivePropagator row "
                + "is expected to fail — a check that has never been seen failing "
                + "is not evidence."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            ForEach(Array(model.findings.enumerated()), id: \.offset) { pair in
                findingRow(pair.element)
            }

            Button("Re-run audit") { model.refreshAudit() }
                .buttonStyle(.bordered)
        }
    }

    private func findingRow(_ finding: AuditFinding) -> some View {
        let expectedFailure = model.isExpectedFailure(finding)
        let behavedAsDesigned = expectedFailure ? !finding.passed : finding.passed
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: behavedAsDesigned ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(behavedAsDesigned ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.invariant)
                        .font(.subheadline.weight(.medium))
                    if expectedFailure {
                        Text("control")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    /// Slider position to a quantity.
    ///
    /// `Int(someDouble)` traps on NaN, on infinity, and on anything outside
    /// `Int`'s range. A `Slider` bound to `0...99` should never produce those,
    /// but "should never" is not a guarantee the runtime enforces, and this is
    /// a conversion on a value the view does not compute itself.
    static func quantity(fromSlider value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded <= 0 { return 0 }
        if rounded >= 99 { return 99 }
        return Int(rounded)
    }

    /// Cents to a display string, without trapping on `Int.min`.
    static func money(_ cents: Int) -> String {
        let dollars = Saturating.divide(cents, 100)
        let rawRemainder = Saturating.remainder(cents, 100)
        // `abs(Int.min)` traps; subtract from zero through the guarded helper.
        let remainder = rawRemainder < 0 ? Saturating.subtract(0, rawRemainder) : rawRemainder
        return "$\(dollars).\(remainder < 10 ? "0" : "")\(remainder)"
    }
}

#Preview {
    CoherenceDemoView(policy: .default)
}
#endif
