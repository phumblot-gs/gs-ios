#if os(iOS)
import SwiftUI
import simd
import GSAPIClient

/// Overlay for the placement step. Sits on top of the live AR view and
/// drives the user through each measurement: the center reticle locks
/// when the device is held steady on a surface, and the bottom panel
/// keeps a running list of captured measurements with per-measurement
/// "redo" buttons.
///
/// Lock logic:
///   - Each measurement needs N points (today: 2).
///   - On lock, the world point is appended to the current measurement.
///   - When the current measurement reaches the target count, we
///     auto-advance to the next incomplete measurement.
///   - "Redo" clears a measurement's points and makes it current.
struct MeasureFlowPlacingOverlay: View {
    let settings: DevSettings
    @ObservedObject var coordinator: MeasureFlowCoordinator
    let category: MeasureCategory
    let referenceFrame: CapturedFrame
    @Binding var captures: [MeasurementCapture]
    let onCancel: () -> Void
    let onValidated: () -> Void

    @State private var currentIndex: Int = 0
    @State private var pulseLock = false
    @State private var pulseTimer: Timer?

    private let pointsPerMeasurement = 2

    var body: some View {
        VStack {
            topBar
            Spacer()
            MeasureLiveReticleHUD(
                stability: coordinator.reticleState?.stability ?? 0,
                pulse: pulseLock
            )
            Spacer()
            bottomPanel
        }
        .onAppear {
            coordinator.onLock = handleLock(world:)
            coordinator.startReticle()
            advanceToFirstIncomplete()
        }
        .onDisappear {
            coordinator.stopReticle()
            coordinator.onLock = nil
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(role: .cancel) { onCancel() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            Spacer()
            Text(category.name)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            currentMeasurementBanner
            measurementsList
            actionButtons
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var currentMeasurementBanner: some View {
        if let current = currentMeasurement {
            let placed = current.worldPoints.count
            let needed = pointsPerMeasurement
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.templateName)
                        .font(.headline)
                    if placed < needed {
                        Text("Point \(placed + 1) of \(needed) — hold the device still on the target.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(formatted(meters: current.meters))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                if placed >= needed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } else {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("All measurements captured. Validate to review.")
                    .font(.subheadline)
            }
        }
    }

    private var measurementsList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(captures.indices, id: \.self) { idx in
                    Button {
                        redo(at: idx)
                    } label: {
                        measurementChip(idx)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func measurementChip(_ idx: Int) -> some View {
        let capture = captures[idx]
        let isCurrent = idx == currentIndex
        let placed = capture.worldPoints.count
        let needed = pointsPerMeasurement
        return HStack(spacing: 6) {
            if capture.isComplete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if placed > 0 {
                Image(systemName: "\(placed).circle").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(capture.templateName).font(.caption.weight(.semibold))
                if capture.isComplete {
                    Text(formatted(meters: capture.meters))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(placed)/\(needed)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) {
                undoLastPoint()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canUndo)

            Button {
                onValidated()
            } label: {
                Label("Validate", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!allComplete)
        }
        .controlSize(.large)
    }

    // MARK: - State derivations

    private var currentMeasurement: MeasurementCapture? {
        captures.indices.contains(currentIndex) ? captures[currentIndex] : nil
    }

    private var canUndo: Bool {
        captures.indices.contains(currentIndex) && !captures[currentIndex].worldPoints.isEmpty
    }

    private var allComplete: Bool {
        !captures.isEmpty && captures.allSatisfy(\.isComplete)
    }

    // MARK: - Actions

    private func handleLock(world: SIMD3<Float>) {
        guard captures.indices.contains(currentIndex) else { return }
        captures[currentIndex].worldPoints.append(world)
        triggerLockPulse()
        if captures[currentIndex].worldPoints.count >= pointsPerMeasurement {
            advanceToNextIncomplete()
        }
    }

    private func advanceToFirstIncomplete() {
        if let idx = captures.firstIndex(where: { !$0.isComplete }) {
            currentIndex = idx
        }
    }

    private func advanceToNextIncomplete() {
        let searchFrom = currentIndex + 1
        if let idx = captures[searchFrom...].firstIndex(where: { !$0.isComplete }) {
            currentIndex = idx
        } else if let idx = captures.firstIndex(where: { !$0.isComplete }) {
            currentIndex = idx
        } else {
            // All complete — stay on the last index but reticle stays
            // active so the user can still trigger a redo manually.
        }
        coordinator.startReticle()   // reset the stability tracker
    }

    private func redo(at idx: Int) {
        captures[idx].worldPoints = []
        currentIndex = idx
        coordinator.startReticle()
    }

    private func undoLastPoint() {
        guard captures.indices.contains(currentIndex) else { return }
        if !captures[currentIndex].worldPoints.isEmpty {
            captures[currentIndex].worldPoints.removeLast()
            coordinator.startReticle()
        }
    }

    private func triggerLockPulse() {
        pulseLock = true
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            Task { @MainActor in pulseLock = false }
        }
    }

    // MARK: - Formatting

    private func formatted(meters: Float) -> String {
        let value = settings.measurementUnit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, settings.measurementUnit.apiSymbol)
    }
}
#endif
