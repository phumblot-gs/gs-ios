#if os(iOS)
import SwiftUI
import simd
import GSAPIClient

/// Overlay for the placement step. Sits on top of the live AR view and
/// drives the user through each measurement: the center reticle locks
/// when the device is held steady on a surface, and the bottom panel
/// shows the captured measurements with their current point count.
///
/// Lock logic:
///   - On lock, the world point is appended to the *current*
///     measurement. The user decides how many points to place per
///     measurement (≥ 2) — there is no auto-advance.
///   - Tap a measurement chip to switch focus. Existing points on
///     other measurements are preserved.
///   - The finalize button at the bottom (label provided by the
///     caller) is enabled once every measurement has ≥ 2 points.
struct MeasureFlowPlacingOverlay: View {
    let settings: DevSettings
    @ObservedObject var coordinator: MeasureFlowCoordinator
    let categoryName: String
    let referenceFrame: CapturedFrame
    let includedSubjects: [DetectedSubject]
    @Binding var captures: [MeasurementCapture]
    let finalizeButtonTitle: LocalizedStringKey
    let finalizeButtonIcon: String
    let onCancel: () -> Void
    let onFinalize: () -> Void

    @State private var currentIndex: Int = 0
    @State private var pulseLock = false
    @State private var pulseTimer: Timer?
    @State private var maskGrid: SubjectMaskGrid = .empty
    @State private var maskDebugImage: UIImage?
    @State private var showReprojectionDebug = false
    @State private var topSafeArea: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0

    private let minimumPointsPerMeasurement = 2

    var body: some View {
        // The reticle sits at the geometric centre of the screen, so
        // the outer ZStack ignores the safe area to span the full
        // viewport. We read the actual safe area insets from the
        // key window at appear time (SwiftUI's GeometryProxy reports
        // zeros inside `.ignoresSafeArea`) and use them to push the
        // top bar and bottom panel down to the same row as the close
        // buttons on the rest of the app's screens.
        ZStack {
            // Tap anywhere in the AR view to force-lock the current
            // point. Touching a button still shakes the device but
            // force-lock uses the averaged window position so the
            // captured point reflects steady aim from before the tap.
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
                    .padding(.top, topSafeArea + 8)
                Spacer()
                bottomPanel
                    .padding(.bottom, bottomSafeArea)
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
                    .padding(.top, topSafeArea + 80)   // clear the X button row
                    Spacer()
                }
                .padding(.leading, 12)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let insets = Self.keyWindowSafeAreaInsets()
            topSafeArea = insets.top
            bottomSafeArea = insets.bottom
            let grid = SubjectMaskGridBuilder.build(
                subjects: includedSubjects,
                imageSize: referenceFrame.image.size
            )
            maskGrid = grid
            maskDebugImage = grid.renderAsImage()
            coordinator.setTarget(referenceFrame: referenceFrame, maskGrid: grid)
            coordinator.onLock = handleLock(world:)
            coordinator.startReticle()
            coordinator.syncMeasurementOverlay(captures: captures)
            advanceToFirstIncomplete()
        }
        .onDisappear {
            coordinator.stopReticle()
            coordinator.onLock = nil
            coordinator.syncMeasurementOverlay(captures: [])
        }
        .onChange(of: captures) { _, newValue in
            coordinator.syncMeasurementOverlay(captures: newValue)
        }
    }

    @MainActor
    private static func keyWindowSafeAreaInsets() -> UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets ?? .zero
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
            Text(categoryName)
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.templateName)
                        .font(.headline)
                    if placed < minimumPointsPerMeasurement {
                        Text("Point \(placed + 1) — hold steady, or tap anywhere to lock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text(formatted(meters: current.meters))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                            Text("· \(placed) points")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if placed >= minimumPointsPerMeasurement {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } else {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("All measurements captured.")
                    .font(.subheadline)
            }
        }
    }

    private var measurementsList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(captures.indices, id: \.self) { idx in
                    Button {
                        selectMeasurement(at: idx)
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
        let isReady = placed >= minimumPointsPerMeasurement
        return HStack(spacing: 6) {
            if isReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if placed > 0 {
                Image(systemName: "\(placed).circle").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(capture.templateName).font(.caption.weight(.semibold))
                if isReady {
                    Text(formatted(meters: capture.meters))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(placed) point(s)")
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
                onFinalize()
            } label: {
                Label(finalizeButtonTitle, systemImage: finalizeButtonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!allReady)
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

    /// All measurements have at least the minimum point count (2).
    /// Variable point counts beyond that are encouraged — the user
    /// might want 3 or 4 points for a curved measurement.
    private var allReady: Bool {
        !captures.isEmpty
            && captures.allSatisfy { $0.worldPoints.count >= minimumPointsPerMeasurement }
    }

    // MARK: - Actions

    private func handleLock(world: SIMD3<Float>) {
        guard captures.indices.contains(currentIndex) else { return }
        captures[currentIndex].worldPoints.append(world)
        triggerLockPulse()
        // No auto-advance — the user signals "done with this
        // measurement" by tapping a different chip. Variable point
        // counts are first-class.
    }

    private func advanceToFirstIncomplete() {
        if let idx = captures.firstIndex(where: { $0.worldPoints.count < minimumPointsPerMeasurement }) {
            currentIndex = idx
        }
    }

    /// Switches focus to the tapped measurement chip. Crucially does
    /// NOT clear the destination measurement's points — the user can
    /// hop between measurements freely and come back to add more.
    /// To clear, use Undo on the current measurement.
    private func selectMeasurement(at idx: Int) {
        guard captures.indices.contains(idx), idx != currentIndex else { return }
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
