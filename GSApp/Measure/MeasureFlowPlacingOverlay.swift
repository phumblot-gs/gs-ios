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
    let includedSubjects: [DetectedSubject]
    @Binding var captures: [MeasurementCapture]
    let onCancel: () -> Void
    let onValidated: () -> Void

    @State private var currentIndex: Int = 0
    @State private var pulseLock = false
    @State private var pulseTimer: Timer?
    @State private var maskGrid: SubjectMaskGrid = .empty
    @State private var maskDebugImage: UIImage?
    @State private var showReprojectionDebug = false

    private let pointsPerMeasurement = 2

    var body: some View {
        // The reticle must sit at the geometric centre of the live AR
        // view, which fills the full screen (via .ignoresSafeArea on
        // ARLiveView). We therefore extend this overlay into the
        // safe area too so the ZStack centre coincides with the
        // screen centre. The top bar and bottom panel use a
        // GeometryReader to read the system safe area insets and pad
        // back in — `.safeAreaPadding` didn't work reliably under
        // `.ignoresSafeArea`, leaving the X button under the Dynamic
        // Island.
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let bottomInset = proxy.safeAreaInsets.bottom
            ZStack {
                // Tap anywhere in the AR view to force-lock the
                // current point. Touching a button still shakes the
                // device but force-lock uses the averaged window
                // position so the captured point reflects steady aim
                // from before the tap.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.forceLockAtCurrentPosition()
                    }

                MeasureLiveReticleHUD(
                    surface: hudSurface,
                    stability: coordinator.reticleState?.stability ?? 0,
                    pulse: pulseLock
                )

                VStack(spacing: 0) {
                    topBar
                        .padding(.top, topInset)
                    Spacer()
                    bottomPanel
                        .padding(.bottom, bottomInset)
                }

                if showReprojectionDebug {
                    VStack {
                        HStack {
                            MeasureReprojectionDebugOverlay(
                                referenceFrame: referenceFrame,
                                maskImage: maskDebugImage,
                                worldPosition: coordinator.reticleState?.worldPosition
                            )
                            Spacer()
                        }
                        .padding(.top, topInset + 56)   // clear the X button row
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let grid = SubjectMaskGridBuilder.build(
                subjects: includedSubjects,
                imageSize: referenceFrame.image.size
            )
            maskGrid = grid
            maskDebugImage = grid.renderAsImage()
            coordinator.setTarget(referenceFrame: referenceFrame, maskGrid: grid)
            coordinator.onLock = handleLock(world:)
            coordinator.startReticle()
            advanceToFirstIncomplete()
        }
        .onDisappear {
            coordinator.stopReticle()
            coordinator.onLock = nil
        }
    }

    private var hudSurface: MeasureLiveReticleHUD.Surface {
        guard let state = coordinator.reticleState else { return .noSurface }
        switch state.surface {
        case .offTarget: return .offTarget
        case .onSubject: return .onSubject
        case .onEdge:    return .onEdge
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
            HStack(spacing: 8) {
                // Debug: toggle the reprojection thumbnail (reference
                // photo + mask + reprojected world point).
                Button {
                    showReprojectionDebug.toggle()
                } label: {
                    Image(systemName: showReprojectionDebug
                          ? "viewfinder.circle.fill"
                          : "viewfinder.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(showReprojectionDebug ? .yellow : .white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                // Debug: toggle the LiDAR mesh overlay.
                Button {
                    coordinator.meshOverlayEnabled.toggle()
                } label: {
                    Image(systemName: coordinator.meshOverlayEnabled
                          ? "square.grid.3x3.fill"
                          : "square.grid.3x3")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(coordinator.meshOverlayEnabled ? .yellow : .white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
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
                        Text("Point \(placed + 1) of \(needed) — hold steady, or tap anywhere to lock.")
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
