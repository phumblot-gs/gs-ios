#if os(iOS)
import SwiftUI
@preconcurrency import ARKit
import RealityKit
import AVFoundation
import simd
import UIKit

/// Single AR coordinator for the whole measure flow. Owns the ARView,
/// runs the world-tracking + scene-reconstruction session across every
/// step (capture → edit → pick category → place points → summary), and
/// exposes high-level operations used by SwiftUI:
///
/// - `captureFrame()` — snapshot the current AR frame as a still photo
///   (used during the capture step).
/// - `startReticle()` / `stopReticle()` — toggle live reticle tracking
///   during the placement step. While on, the coordinator publishes a
///   `reticleState` on each ARFrame, locks the point when the user
///   holds the device steady, and renders a 3D disc on the surface.
///
/// Keeping a single session alive matters: the world points captured at
/// placement time live in the same coordinate frame as
/// `CapturedFrame.cameraTransform`, so we can reproject them onto the
/// reference photo in the summary view.
@MainActor
final class MeasureFlowCoordinator: NSObject, ObservableObject {

    // MARK: - State exposed to SwiftUI

    /// Latest reticle update while tracking is active. Nil when not
    /// tracking, or when the depth raycast finds no valid surface.
    @Published private(set) var reticleState: ReticleState?

    /// Locked world points are pushed here for the placement view to
    /// consume. Reset between measurements.
    var onLock: ((SIMD3<Float>) -> Void)?

    /// Debug toggle: when on, ARView renders the reconstructed LiDAR
    /// mesh as a wireframe on top of the camera feed. Useful for
    /// diagnosing whether the reticle hits the surface ARKit actually
    /// sees vs. drifting in space.
    @Published var meshOverlayEnabled: Bool = false {
        didSet { applyDebugOverlay() }
    }

    struct ReticleState: Equatable {
        enum Surface: Equatable { case offTarget, onSubject, onEdge }
        let worldPosition: SIMD3<Float>
        let surface: Surface
        let stability: Float          // 0…1; 0 when surface == .offTarget
    }

    // MARK: - Internals

    private weak var arView: ARView?
    private let ciContext = CIContext()
    private let stability = MeasureStabilityTracker()
    private var isTrackingReticle = false

    // Mask-based target gating. Set by the placing overlay so the
    // reticle only progresses when reprojected onto the kept subject.
    private var referenceFrame: CapturedFrame?
    private var maskGrid: SubjectMaskGrid = .empty
    private var currentSurface: ReticleState.Surface = .offTarget

    // The 3D disc rendered on the surface to confirm where the next
    // point will land. Anchored to the world; updated each frame.
    private var reticleAnchor: AnchorEntity?
    private var reticleDisc: ModelEntity?

    // 3D overlay for points already locked in the current flow.
    // One AnchorEntity holding spheres at each locked point and thin
    // cylinders connecting consecutive points of the same measurement.
    // World-anchored so they stay glued to the product as the user
    // moves around to place the next point.
    private var measurementOverlayAnchor: AnchorEntity?

    // "Z-guide" placement constraint. When active, the next world
    // point is projected onto a vertical plane passing through the
    // anchor with normal = horizontal direction the camera was
    // facing when the guide was enabled. The reticle then slides
    // "along the plane", which is the right tool to measure heights
    // and edges on volumetric products.
    enum GuideMode { case off, zAxis }
    @Published private(set) var guideMode: GuideMode = .off
    private var guideAnchor: SIMD3<Float>?
    private var guidePlaneNormal: SIMD3<Float>?
    private var guideLineAnchor: AnchorEntity?

    // Horizontal planes ARKit has detected. Used to snap the descending
    // reticle to the "support" (the table under the product) when the
    // Z-guide is on — so the user can drop the second endpoint of a
    // height measurement directly onto the table without having to
    // hold the device perfectly still at table level.
    private var horizontalPlanes: [UUID: ARPlaneAnchor] = [:]
    private var wasSnappedToSupport = false
    private let supportSnapDistance: Float = 0.02   // 2 cm

    private let lockSoundID: SystemSoundID = 1113   // "Begin Recording"

    // MARK: - Lifecycle

    func attach(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        installReticleEntity(in: arView)
        applyDebugOverlay()
    }

    private func applyDebugOverlay() {
        // Edges-only wireframe via Apple's built-in debug option.
        // The custom filled-triangle overlay we tried earlier covered
        // the live view too aggressively to be useful for diagnosing
        // alignment; the wireframe gives the same spatial info without
        // hiding the underlying camera image.
        guard let arView else { return }
        if meshOverlayEnabled {
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    // MARK: - Capture

    /// Take the current ARFrame and convert it to a `CapturedFrame`.
    func captureFrame() -> CapturedFrame? {
        guard let frame = arView?.session.currentFrame else { return nil }
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        let depth = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        return CapturedFrame(
            image: uiImage,
            depthMap: depth,
            cameraTransform: frame.camera.transform,
            cameraIntrinsics: frame.camera.intrinsics
        )
    }

    // MARK: - Reticle

    func startReticle() {
        isTrackingReticle = true
        currentSurface = .offTarget
        stability.reset()
        reticleDisc?.isEnabled = true
    }

    func stopReticle() {
        isTrackingReticle = false
        reticleState = nil
        currentSurface = .offTarget
        reticleDisc?.isEnabled = false
    }

    /// Rebuild the 3D overlay of already-locked measurement points and
    /// segments to match the current captures. Called every time the
    /// placing view's captures array changes — append, undo, redo. We
    /// recreate the whole entity tree each time rather than diffing;
    /// the count is tiny (a few spheres + cylinders) so the overhead
    /// is negligible.
    func syncMeasurementOverlay(captures: [MeasurementCapture]) {
        guard let arView else { return }
        measurementOverlayAnchor?.removeFromParent()
        measurementOverlayAnchor = nil

        let anchor = AnchorEntity(world: .zero)
        for (idx, capture) in captures.enumerated() {
            let material = Self.measurementMaterial(at: idx)
            for point in capture.worldPoints {
                anchor.addChild(Self.makePointMarker(at: point, material: material))
            }
            guard capture.worldPoints.count > 1 else { continue }
            for i in 0..<(capture.worldPoints.count - 1) {
                let segment = Self.makeSegmentEntity(
                    from: capture.worldPoints[i],
                    to: capture.worldPoints[i + 1],
                    material: material
                )
                anchor.addChild(segment)
            }
        }
        arView.scene.addAnchor(anchor)
        measurementOverlayAnchor = anchor
    }

    private static let measurementColors: [UIColor] = [
        .systemGreen,
        .systemCyan,
        .systemPink,
        .systemOrange,
        .systemPurple
    ]

    private static func measurementMaterial(at index: Int) -> UnlitMaterial {
        let color = measurementColors[index % measurementColors.count]
        var mat = UnlitMaterial()
        mat.color = .init(tint: color)
        mat.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        return mat
    }

    private static func makePointMarker(at world: SIMD3<Float>, material: UnlitMaterial) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 0.006)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.transform = Transform(translation: world)
        return entity
    }

    private static func makeSegmentEntity(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        material: UnlitMaterial
    ) -> ModelEntity {
        let length = simd_distance(a, b)
        let midpoint = (a + b) / 2
        let mesh = MeshResource.generateCylinder(height: length, radius: 0.0025)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        // Cylinder mesh is generated along the Y axis. Rotate so it
        // points from `a` to `b`; `simd_quatf(from:to:)` builds the
        // shortest rotation between two unit vectors.
        let direction = simd_normalize(b - a)
        let up = SIMD3<Float>(0, 1, 0)
        let rotation = simd_quatf(from: up, to: direction)
        entity.transform = Transform(scale: .one, rotation: rotation, translation: midpoint)
        return entity
    }

    /// Enable the Z-guide constraint. Captures the current camera's
    /// horizontal forward direction as the plane normal so the plane
    /// is roughly facing the user — exactly the "vertical slice in
    /// front of me" the user wants when measuring heights. Re-call
    /// this each time the anchor changes (e.g. after a new lock) to
    /// keep the visual line in sync.
    func enableZGuide(anchor: SIMD3<Float>) {
        guard let arView, let frame = arView.session.currentFrame else { return }
        // ARKit's camera transform stores `back` in column 2; the
        // forward direction is therefore the negated column 2.
        let cameraForward = -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )
        var horizontal = SIMD3<Float>(cameraForward.x, 0, cameraForward.z)
        let len = simd_length(horizontal)
        // If the camera is pointed straight up/down, the horizontal
        // component is zero — keep whatever direction we already had.
        if len > 0.01 {
            horizontal /= len
            guidePlaneNormal = horizontal
        }
        guideAnchor = anchor
        guideMode = .zAxis
        guideLineLastSupportY = .nan   // force re-render with new anchor
        refreshGuideLine()
    }

    func disableGuide() {
        guideMode = .off
        guideAnchor = nil
        guidePlaneNormal = nil
        wasSnappedToSupport = false
        removeGuideLine()
    }

    private var guideLineEntity: ModelEntity?
    private var guideLineLastSupportY: Float? = .nan   // sentinel = "never applied"

    /// Render (or update) the guide line as a *half-line* starting at
    /// the anchor and descending to the support altitude. When the
    /// support hasn't been detected yet we fall back to a fixed
    /// 30 cm downward extension. The portion that would lie under
    /// the table is intentionally not drawn — visually clearer than
    /// the previous symmetric 60 cm cylinder centred on the anchor.
    private func refreshGuideLine() {
        guard guideMode == .zAxis, let anchor = guideAnchor else {
            removeGuideLine()
            return
        }
        let supportY = supportAltitudeBelowAnchor()
        // Skip the render when nothing about the geometry has changed
        // — the entity's transform was already correct.
        if guideLineEntity != nil && guideLineLastSupportY == supportY { return }
        guideLineLastSupportY = supportY

        let length: Float
        let bottomY: Float
        if let supportY {
            length = max(0.01, anchor.y - supportY)
            bottomY = supportY
        } else {
            length = 0.30
            bottomY = anchor.y - length
        }

        if guideLineEntity == nil {
            guard let arView else { return }
            let mesh = MeshResource.generateCylinder(height: 1, radius: 0.0015)
            var mat = UnlitMaterial()
            mat.color = .init(tint: .systemBlue)
            mat.blending = .transparent(opacity: .init(floatLiteral: 0.75))
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            let container = AnchorEntity(world: .zero)
            container.addChild(entity)
            arView.scene.addAnchor(container)
            guideLineAnchor = container
            guideLineEntity = entity
        }

        let midY = bottomY + length / 2
        guideLineEntity?.transform = Transform(
            scale: SIMD3<Float>(1, length, 1),
            rotation: .init(),
            translation: SIMD3<Float>(anchor.x, midY, anchor.z)
        )
    }

    private func removeGuideLine() {
        guideLineAnchor?.removeFromParent()
        guideLineAnchor = nil
        guideLineEntity = nil
        guideLineLastSupportY = .nan
    }

    /// Apply the Z-guide plane projection if active. The plane passes
    /// through `guideAnchor` with `guidePlaneNormal` as its (horizontal)
    /// normal; the projected point is the closest point in that plane
    /// to the input world position.
    private func applyGuideConstraint(to world: SIMD3<Float>) -> SIMD3<Float> {
        guard guideMode == .zAxis,
              let anchor = guideAnchor,
              let normal = guidePlaneNormal else { return world }
        let delta = world - anchor
        let distanceAlongNormal = simd_dot(delta, normal)
        return world - distanceAlongNormal * normal
    }

    /// Highest detected horizontal-plane altitude that's still below
    /// the Z-guide anchor — the "support" the user wants to snap to
    /// when measuring heights. Returns nil if no plane has been
    /// detected yet or none lies below the anchor.
    private func supportAltitudeBelowAnchor() -> Float? {
        guard let anchor = guideAnchor else { return nil }
        var best: Float?
        for plane in horizontalPlanes.values {
            let centerWorld = plane.transform * SIMD4<Float>(
                plane.center.x, plane.center.y, plane.center.z, 1
            )
            let altitude = centerWorld.y
            // The plane must be below the anchor by a margin — a
            // plane "at" the anchor level is almost certainly the top
            // face of the product, not the table.
            if altitude > anchor.y - 0.02 { continue }
            if best == nil || altitude > best! { best = altitude }
        }
        return best
    }

    /// Snap the guide-constrained world point onto the support
    /// altitude when it descends into the snap zone. Returns the
    /// (possibly snapped) world point and whether the snap engaged
    /// — the caller uses that flag to color the disc and emit a
    /// haptic on the snap-entry transition.
    private func applySupportSnap(to world: SIMD3<Float>) -> (world: SIMD3<Float>, snapped: Bool) {
        guard guideMode == .zAxis,
              let supportY = supportAltitudeBelowAnchor() else {
            return (world, false)
        }
        if abs(world.y - supportY) <= supportSnapDistance {
            return (SIMD3<Float>(world.x, supportY, world.z), true)
        }
        return (world, false)
    }

    /// Manually force-lock the current reticle position. Triggered by
    /// tap-anywhere-on-screen so the user can commit a point without
    /// waiting for the stability ring to top up — the act of tapping
    /// the screen jolts the device just enough to make the
    /// auto-lock's variance check fail, which is what bit the user.
    /// We use the stability tracker's averaged window position so the
    /// captured point reflects the steady aim from ~300 ms before the
    /// tap, not the tap-induced jitter.
    func forceLockAtCurrentPosition() {
        guard isTrackingReticle,
              let current = reticleState,
              current.surface != .offTarget else { return }
        let position = stability.averagedPosition ?? current.worldPosition
        AudioServicesPlaySystemSound(lockSoundID)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onLock?(position)
        stability.reset()
    }

    /// Hand the coordinator the reference photo + a rasterized mask of
    /// the kept subjects. While set, the reticle only progresses on
    /// pixels that reproject inside the mask; pixels near the mask
    /// boundary use a tighter stability profile so the lock hooks
    /// faster onto product edges.
    func setTarget(referenceFrame: CapturedFrame, maskGrid: SubjectMaskGrid) {
        self.referenceFrame = referenceFrame
        self.maskGrid = maskGrid
    }

    private func installReticleEntity(in arView: ARView) {
        let anchor = AnchorEntity(world: .zero)
        let disc = makeReticleDisc()
        anchor.addChild(disc)
        arView.scene.addAnchor(anchor)
        reticleAnchor = anchor
        reticleDisc = disc
        disc.isEnabled = false
    }

    private func makeReticleDisc() -> ModelEntity {
        // Thin disc lying in the XZ plane (Y is up in RealityKit). We
        // override its transform + tint each frame.
        let radius: Float = 0.012   // 1.2 cm
        let mesh = MeshResource.generatePlane(width: radius * 2, depth: radius * 2, cornerRadius: radius)
        return ModelEntity(mesh: mesh, materials: [Self.material(for: .white)])
    }

    /// Cache one material per tint colour we use so we're not
    /// allocating fresh `UnlitMaterial` instances on every frame.
    /// Setting an alpha component on the color tint alone doesn't
    /// trigger blending in RealityKit; we have to explicitly opt into
    /// `.transparent(opacity:)` for the disc to actually let the
    /// camera feed show through.
    private static let materialCache: [String: UnlitMaterial] = {
        let colors: [UIColor] = [.white, .systemYellow, .systemRed]
        var dict: [String: UnlitMaterial] = [:]
        for color in colors {
            var mat = UnlitMaterial(color: color)
            mat.color = .init(tint: color)
            mat.blending = .transparent(opacity: .init(floatLiteral: 0.4))
            dict[color.description] = mat
        }
        return dict
    }()

    private static func material(for color: UIColor) -> UnlitMaterial {
        materialCache[color.description] ?? UnlitMaterial(color: color)
    }

    // MARK: - Per-frame processing

    fileprivate func handleFrame(_ frame: ARFrame) {
        guard isTrackingReticle, let arView else { return }
        guard let raw = projectScreenCenter(of: arView, in: frame) else {
            transitionSurface(to: .offTarget)
            reticleState = nil
            reticleDisc?.isEnabled = false
            return
        }

        // Z-guide projection happens before classification and
        // stability so every downstream step sees the constrained
        // position. With guide off this is a no-op.
        let projected = applyGuideConstraint(to: raw.world)
        let snapResult = applySupportSnap(to: projected)
        let world = snapResult.world
        let isGuideOn = guideMode == .zAxis
        let snappedToSupport = snapResult.snapped

        // Refresh the guide line geometry — picks up newly-detected
        // support planes so the line stops at the table even when
        // ARKit only resolves the plane after the user enabled the
        // guide. Internally bails out when nothing has changed.
        if isGuideOn { refreshGuideLine() }

        if snappedToSupport != wasSnappedToSupport {
            if snappedToSupport {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            wasSnappedToSupport = snappedToSupport
        }

        let surface = classifySurface(world: world)
        // With Z-guide on, off-subject points are valid placements
        // (the table below the product is intentionally outside the
        // reference photo's mask). Treat it as on-subject for the
        // stability path so the user can lock the lower endpoint of
        // a height measurement.
        let effectiveSurface: ReticleState.Surface = (isGuideOn && surface == .offTarget) ? .onSubject : surface
        transitionSurface(to: effectiveSurface)

        switch effectiveSurface {
        case .offTarget:
            // Reticle is on a depthful surface but not on the kept
            // subject — keep the 3D disc visible (red) so the user
            // sees where they're aiming, but freeze the stability ring.
            updateReticleTransform(world: world, normal: raw.normal, color: .systemRed)
            reticleDisc?.isEnabled = true
            reticleState = ReticleState(worldPosition: world, surface: .offTarget, stability: 0)
            return
        case .onSubject:
            stability.setProfile(.subject)
        case .onEdge:
            stability.setProfile(.edge)
        }

        let (score, locked) = stability.observe(position: world)
        let displayedPos = stability.averagedPosition ?? world
        let color: UIColor
        if snappedToSupport {
            color = .systemBlue
        } else {
            color = effectiveSurface == .onEdge ? .systemYellow : .white
        }
        updateReticleTransform(world: displayedPos, normal: raw.normal, color: color)
        reticleDisc?.isEnabled = true
        reticleState = ReticleState(worldPosition: displayedPos, surface: effectiveSurface, stability: score)

        if locked {
            AudioServicesPlaySystemSound(lockSoundID)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLock?(displayedPos)
        }
    }

    /// Reproject `world` onto the reference photo (portrait normalized
    /// coords) and sample the rasterized subject mask to decide the
    /// surface category. Falls back to `.onSubject` when no mask was
    /// provided (e.g. no kept subjects).
    private func classifySurface(world: SIMD3<Float>) -> ReticleState.Surface {
        guard let referenceFrame, !maskGrid.isEmpty else { return .onSubject }
        guard let normalized = MeasureReprojection.projectToNormalized(
            worldPoint: world,
            frame: referenceFrame
        ) else {
            return .offTarget
        }
        switch maskGrid.sample(normalizedImagePoint: normalized) {
        case .off:     return .offTarget
        case .subject: return .onSubject
        case .edge:    return .onEdge
        }
    }

    private func transitionSurface(to next: ReticleState.Surface) {
        guard next != currentSurface else { return }
        // Surface change → reset the stability so partial progress
        // from a previous spot doesn't carry over.
        stability.reset()
        // Light haptic when hooking onto the subject from off-target;
        // tighter "selection changed" when crossing onto an edge.
        if currentSurface == .offTarget && next != .offTarget {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if next == .onEdge {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        currentSurface = next
    }

    private func updateReticleTransform(world: SIMD3<Float>, normal: SIMD3<Float>, color: UIColor) {
        guard let disc = reticleDisc else { return }
        // Build an orthonormal basis whose Y axis = surface normal.
        let n = simd_normalize(normal)
        // Pick an "up" reference that isn't collinear with n.
        let ref: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let xAxis = simd_normalize(simd_cross(ref, n))
        let zAxis = simd_normalize(simd_cross(n, xAxis))
        let basis = simd_float3x3(columns: (xAxis, n, zAxis))
        let rotation = simd_quatf(basis)
        disc.transform = Transform(scale: .one, rotation: rotation, translation: world)
        disc.model?.materials = [Self.material(for: color)]
    }

    /// Sample the depth at the screen center and project to world coords.
    /// Returns the world position and the surface normal estimated from
    /// neighboring depth samples.
    private func projectScreenCenter(of arView: ARView, in frame: ARFrame) -> (world: SIMD3<Float>, normal: SIMD3<Float>)? {
        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        guard let depthMap else { return nil }
        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        // ARView aligns the camera's *principal point* (cx, cy) — not
        // the image's geometric centre — to the screen centre. So the
        // visible reticle (at screen centre) corresponds to the depth
        // map pixel at the principal point, not at (0.5, 0.5). The two
        // differ by a few pixels on the sensor due to manufacturing
        // tolerances; that small offset was enough to make the depth
        // raycast land beside small subjects (e.g. a LEGO car), giving
        // a world point on the surrounding table and forcing the mask
        // check to read .offTarget.
        let cxNorm = CGFloat(frame.camera.intrinsics[2, 0]) / CGFloat(imageWidth)
        let cyNorm = CGFloat(frame.camera.intrinsics[2, 1]) / CGFloat(imageHeight)
        let normalizedDepthPoint = CGPoint(x: cxNorm, y: cyNorm)
        guard let pCameraLocal = DepthRaycaster.project(
            normalizedPoint: normalizedDepthPoint,
            depthMap: depthMap,
            intrinsics: frame.camera.intrinsics,
            imageSize: CGSize(width: imageWidth, height: imageHeight)
        ) else { return nil }

        // DepthRaycaster returns OpenCV-convention coordinates (Y down,
        // +Z forward), but `camera.transform` is ARKit-convention
        // (Y up, +Z back toward viewer). Flip Y and Z to convert before
        // applying the transform — otherwise the world point lands in
        // a hybrid frame and `MeasureReprojection.projectToNormalized`
        // sends it "behind the camera", forcing the mask check to
        // permanently report off-target.
        let pCameraArkit = SIMD3<Float>(pCameraLocal.x, -pCameraLocal.y, -pCameraLocal.z)
        let pWorld4 = frame.camera.transform * SIMD4<Float>(pCameraArkit, 1)
        let pWorld = SIMD3<Float>(pWorld4.x, pWorld4.y, pWorld4.z)

        // Surface normal: sample two nearby depth pixels and take the
        // cross product of the resulting 3D differences. Fall back to
        // "facing the camera" if the neighbors are invalid.
        let normalWorld = computeNormal(
            atCenter: pCameraLocal,
            atNormalizedPoint: normalizedDepthPoint,
            depthMap: depthMap,
            intrinsics: frame.camera.intrinsics,
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            cameraTransform: frame.camera.transform
        ) ?? -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )

        return (pWorld, normalWorld)
    }

    private func computeNormal(
        atCenter pCenter: SIMD3<Float>,
        atNormalizedPoint centerNorm: CGPoint,
        depthMap: CVPixelBuffer,
        intrinsics: simd_float3x3,
        imageSize: CGSize,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let offset: CGFloat = 0.02
        guard let pRight = DepthRaycaster.project(
            normalizedPoint: CGPoint(x: centerNorm.x + offset, y: centerNorm.y),
            depthMap: depthMap,
            intrinsics: intrinsics,
            imageSize: imageSize
        ), let pDown = DepthRaycaster.project(
            normalizedPoint: CGPoint(x: centerNorm.x, y: centerNorm.y + offset),
            depthMap: depthMap,
            intrinsics: intrinsics,
            imageSize: imageSize
        ) else { return nil }

        // Normals in camera-local space; convert to world via the
        // camera transform's rotation (3×3 sub-matrix).
        let v1 = pRight - pCenter
        let v2 = pDown - pCenter
        let nCamera = simd_normalize(simd_cross(v1, v2))
        // Flip so the normal points away from the surface (toward the
        // camera): camera is at origin in camera-local, surface is in
        // +Z; the surface normal should have negative Z.
        let nCamFacing = nCamera.z > 0 ? -nCamera : nCamera

        // Same OpenCV → ARKit flip as for positions above so the
        // rotation lifts the normal into the ARKit world frame.
        let nArkit = SIMD3<Float>(nCamFacing.x, -nCamFacing.y, -nCamFacing.z)
        let rotation = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        return simd_normalize(rotation * nArkit)
    }
}

// MARK: - ARSessionDelegate

extension MeasureFlowCoordinator: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // delegateQueue = .main → we're already on the main actor; the
        // hop below is just to satisfy the Swift 6 isolation checker.
        MainActor.assumeIsolated {
            self.handleFrame(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for anchor in anchors {
                if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                    self.horizontalPlanes[plane.identifier] = plane
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for anchor in anchors {
                if let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal {
                    self.horizontalPlanes[plane.identifier] = plane
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for anchor in anchors {
                self.horizontalPlanes.removeValue(forKey: anchor.identifier)
            }
        }
    }
}
#endif
