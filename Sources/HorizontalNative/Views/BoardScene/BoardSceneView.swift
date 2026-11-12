#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Metal
import RealityKit
import simd
import SwiftUI

enum HorizontalBoard3DViewPreset: String, CaseIterable, Identifiable {
    case defaultPerspective
    case top
    case bottom
    case frontLeft
    case side
    case backRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultPerspective: "Default Perspective"
        case .top: "Top"
        case .bottom: "Bottom"
        case .side: "Left"
        case .frontLeft: "Front"
        case .backRight: "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultPerspective: "cube"
        case .top: "arrow.down"
        case .bottom: "arrow.up"
        case .side: "arrow.right"
        case .frontLeft: "arrow.up.right"
        case .backRight: "arrow.left"
        }
    }

    var projection: HorizontalBoardSceneProjection {
        self == .defaultPerspective ? .perspective : .orthogonal
    }
}

/// What the 3D view is doing behind the picture it shows.
enum BoardSceneBuildState: Equatable {
    case idle
    /// Nothing to show yet: the first scene is being built.
    case building
    /// The scene on screen is the previous board's; a newer one is coming.
    case updating
}

struct BoardSceneView: View {
    var board: HorizontalBoard
    var displayOptions: BoardDisplayOptions
    var backgroundColor: Color
    var copperColor: Color = Color(red: 0.72, green: 0.45, blue: 0.2)
    var layerColors: [Int: HorizontalRGBColor] = [:]
    var materialColors = HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil)
    var ignoresSceneMouseEvents = false
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    /// Bumped by the host whenever the board's content changes. The scene
    /// is rebuilt in the background once edits settle; the old one stays
    /// up until the new one is ready.
    var revision: Int = 0
    /// Components to mark in the scene, by id — the same set the canvases
    /// highlight, so "highlight C50" is one highlight in every view.
    var highlightedComponentIDs: Set<String> = []
    /// Components to mark as selected, by id — the canvases' selection.
    var selectedComponentIDs: Set<String> = []
    /// A click or tap on a part: its component id, and whether the click
    /// extends the selection (shift or command). Nil id is empty space.
    var onSelectComponent: ((String?, Bool) -> Void)? = nil
    /// The insets of the bars and the home indicator, for a pane that runs
    /// under them and is handed them instead of a safe area: the status
    /// overlay keeps clear of them.
    var safeAreaInsets = EdgeInsets()
    @Binding var cameraState: HorizontalSceneCameraState?
    @State private var buildState: BoardSceneBuildState = .idle

    var body: some View {
        // The scene is built lazily inside the host view's coordinator and
        // cached on `(board.url, board.uuid, revision, render display options)`.
        // We must not build it from `body` — `body` re-runs every time the
        // parent's `@State threeDCameraState` updates (which happens on every
        // pan/zoom event), and rebuilding the scene per gesture is what made
        // the 3D view sluggish.
        //
        // Likewise, no `.id(displayOptions)` here: a layer toggle should swap
        // the scene in place, not destroy and recreate the underlying view.
        BoardSceneHostView(
            board: board,
            displayOptions: displayOptions,
            backgroundColor: backgroundColor,
            copperColor: copperColor,
            layerColors: layerColors,
            materialColors: materialColors,
            ignoresSceneMouseEvents: ignoresSceneMouseEvents,
            silkscreenClipping: silkscreenClipping,
            revision: revision,
            highlightedComponentIDs: highlightedComponentIDs,
            selectedComponentIDs: selectedComponentIDs,
            onSelectComponent: onSelectComponent,
            cameraState: $cameraState,
            buildState: $buildState
        )
        .background(horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions))
        .overlay {
            if buildState == .building {
                ProgressView("Building 3D view…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay {
            if buildState == .updating {
                // Moved in from a rounded window or display corner, which
                // would otherwise cut into it.
                Color.clear
                    .cornerAdaptiveOverlay(alignment: .bottomTrailing, padding: 12) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating…")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .safeAreaPadding(safeAreaInsets)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Caches a board's scene by board identity and edit revision so the host
/// view can be re-evaluated freely without paying for a rebuild. Display
/// options, colors, and explode are applied as in-place changes — only a
/// changed board triggers a rebuild.
///
/// The slow part of a build — clipping, triangulating, laying out vertices —
/// runs off the main thread and hands over plain meshes; only copying those
/// into RealityKit's buffers happens on the main actor, where RealityKit's
/// entities live. An edit to a board that already has a scene keeps that
/// scene on screen: the rebuild starts once the edits have settled, runs one
/// at a time, and picks up whatever arrived meanwhile in one more pass.
@MainActor
final class BoardSceneSceneCache {
    /// How long edits are left to settle before a rebuild starts.
    static let editSettleDelay: Duration = .milliseconds(400)

    private var key: BoardSceneCacheKey?
    private var entities: BoardSceneEntities?
    private var requestedKey: BoardSceneCacheKey?
    private var requestedBoard: HorizontalBoard?
    private var requestedClipping: HorizontalSilkscreenClipping?
    private var onReady: (@MainActor (BoardSceneEntities) -> Void)?
    private var buildKey: BoardSceneCacheKey?
    private var settleTask: Task<Void, Never>?

    /// The scene for `board` when it is built. Otherwise the previous
    /// board's scene as a stand-in (nil before the first build), with a
    /// build under way or pending that hands the new scene to `onReady` on
    /// the main actor.
    func scene(
        for board: HorizontalBoard,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        revision: Int = 0,
        onReady: @escaping @MainActor (BoardSceneEntities) -> Void
    ) -> BoardSceneEntities? {
        let candidate = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping, revision: revision)
        self.onReady = onReady
        guard candidate != requestedKey else {
            return entities
        }
        requestedKey = candidate
        requestedBoard = board
        requestedClipping = silkscreenClipping
        settleTask?.cancel()
        settleTask = nil
        if candidate == key {
            // Back to what is built (a toggle undone within the delay).
            return entities
        }
        if buildKey == nil {
            if entities == nil {
                // Nothing on screen yet: build at once.
                startBuild()
            } else {
                settleTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.editSettleDelay)
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    self.settleTask = nil
                    self.startBuild()
                }
            }
        }
        return entities
    }

    private func startBuild() {
        guard buildKey == nil,
              let requestedKey,
              requestedKey != key,
              let board = requestedBoard else {
            return
        }
        let clipping = requestedClipping
        buildKey = requestedKey
        Task.detached(priority: .userInitiated) { [weak self] in
            let description = BoardSceneFactory.describeScene(for: board, silkscreenClipping: clipping)
            await self?.finishBuild(description, key: requestedKey)
        }
    }

    private func finishBuild(_ description: BoardSceneDescription, key builtKey: BoardSceneCacheKey) {
        buildKey = nil
        guard requestedKey == builtKey else {
            // A live edit or undo arrived during the build. Never present
            // its predecessor over the newer document.
            startBuild()
            return
        }
        let built = BoardSceneEntities(description: description)
        key = builtKey
        entities = built
        onReady?(built)
        // Edits that arrived while building: one more pass, now.
        if requestedKey != builtKey {
            startBuild()
        }
    }

    /// A build is running or waiting for edits to settle.
    var isBuilding: Bool {
        buildKey != nil || (requestedKey != nil && requestedKey != key)
    }

    /// The revision of the scene on screen, for tests.
    var builtRevision: Int? {
        key?.revision
    }
}

struct BoardSceneCacheKey: Hashable {
    var boardURL: URL
    var boardUUID: String
    var boardName: String
    var stackupLayers: [HorizontalBoardStackupLayer]
    var userLayers: [HorizontalBoardUserLayer]
    var silkscreenClipping: HorizontalSilkscreenClipping?
    /// The host's count of edits to the board's content.
    var revision: Int

    init(board: HorizontalBoard, silkscreenClipping: HorizontalSilkscreenClipping? = nil, revision: Int = 0) {
        self.silkscreenClipping = silkscreenClipping
        self.revision = revision
        self.boardURL = board.url
        self.boardUUID = board.uuid
        self.boardName = board.name
        self.stackupLayers = board.stackupLayers
        self.userLayers = board.userLayers
    }
}

private struct BoardSceneColorKey: Hashable {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Int

    #if canImport(AppKit)
    init(_ color: Color, appearance: NSAppearance? = nil) {
        var nsColor = HorizontalDefaultTheme.backgroundNS
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            }
        } else {
            nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        self.init(nsColor)
    }

    private init(_ color: NSColor) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        self.red = Self.quantize(resolved.redComponent)
        self.green = Self.quantize(resolved.greenComponent)
        self.blue = Self.quantize(resolved.blueComponent)
        self.alpha = Self.quantize(resolved.alphaComponent)
    }
    #else
    init(_ color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.red = Self.quantize(red)
        self.green = Self.quantize(green)
        self.blue = Self.quantize(blue)
        self.alpha = Self.quantize(alpha)
    }
    #endif

    private static func quantize(_ component: CGFloat) -> Int {
        Int((Double(component) * 10_000).rounded())
    }
}

/// Which surfaces the 3D scene shows: the 3D view's own toggles, never the
/// 2D layer eyes. The package editor hides mask and paste in 2D and the
/// board editor can hide the outline; the 3D view still shows the board.
struct BoardSceneSurfaceVisibility: Equatable {
    var substrate: Bool
    var solderMask: Bool
    var silkscreen: Bool
    var paste: Bool

    init(_ options: BoardDisplayOptions) {
        substrate = options.threeDBoardBody
        solderMask = options.threeDSolderMask
        silkscreen = options.threeDSilkscreen
        paste = options.threeDPaste
    }
}

private struct BoardSceneDisplayOptionsKey: Hashable {
    var boardBody: Bool
    var solderMask: Bool
    var silkscreen: Bool
    var paste: Bool
    var vias: Bool
    var holes: Bool
    var text: Bool
    var packages: Bool
    var decals: Bool
    var keepouts: Bool
    var origin: Bool
    var orientationAxes: Bool
    var outline: Bool
    var panelLabels: Bool
    var projection: HorizontalBoardSceneProjection
    var explode: Double
    var background: Bool
    var shadows: Bool
    var solderMaskTransparency: Double
    var viaPlatingMicrons: Double
    var copperMode: HorizontalBoardSceneCopperMode
    var modelMode: HorizontalBoardSceneModelMode

    init(_ options: BoardDisplayOptions) {
        // The 3D view's own surface toggles, not the 2D layer eyes.
        self.boardBody = options.threeDBoardBody
        self.solderMask = options.threeDSolderMask
        self.silkscreen = options.threeDSilkscreen
        self.paste = options.threeDPaste
        self.vias = options.vias
        self.holes = options.holes
        self.text = options.text
        self.packages = options.packages
        self.decals = options.decals
        self.keepouts = options.keepouts
        self.origin = options.origin
        self.orientationAxes = options.orientationAxes
        self.outline = options.outline
        self.panelLabels = options.panelLabels
        self.projection = options.threeDProjection
        self.explode = options.threeDExplode
        self.background = options.threeDBackground
        self.shadows = options.threeDShadows
        self.solderMaskTransparency = options.threeDSolderMaskTransparency
        self.viaPlatingMicrons = options.threeDViaPlatingMicrons
        self.copperMode = options.threeDCopperMode
        self.modelMode = options.threeDModelMode
    }
}

private struct BoardSceneAppliedOptionsKey: Hashable {
    var sceneKey: BoardSceneCacheKey
    var displayOptions: BoardSceneDisplayOptionsKey
    var backgroundColor: BoardSceneColorKey
    var copperColor: BoardSceneColorKey
    var layerColors: [Int: HorizontalRGBColor]
    var materialColors: HorizontalBoardColors

    #if canImport(AppKit)
    init(
        board: HorizontalBoard,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        revision: Int = 0,
        displayOptions: BoardDisplayOptions,
        backgroundColor: Color,
        copperColor: Color,
        layerColors: [Int: HorizontalRGBColor],
        materialColors: HorizontalBoardColors,
        appearance: NSAppearance
    ) {
        self.sceneKey = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping, revision: revision)
        self.displayOptions = BoardSceneDisplayOptionsKey(displayOptions)
        self.backgroundColor = BoardSceneColorKey(backgroundColor, appearance: appearance)
        self.copperColor = BoardSceneColorKey(copperColor, appearance: appearance)
        self.layerColors = layerColors
        self.materialColors = materialColors
    }
    #else
    init(
        board: HorizontalBoard,
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        revision: Int = 0,
        displayOptions: BoardDisplayOptions,
        backgroundColor: Color,
        copperColor: Color,
        layerColors: [Int: HorizontalRGBColor],
        materialColors: HorizontalBoardColors
    ) {
        self.sceneKey = BoardSceneCacheKey(board: board, silkscreenClipping: silkscreenClipping, revision: revision)
        self.displayOptions = BoardSceneDisplayOptionsKey(displayOptions)
        self.backgroundColor = BoardSceneColorKey(backgroundColor)
        self.copperColor = BoardSceneColorKey(copperColor)
        self.layerColors = layerColors
        self.materialColors = materialColors
    }
    #endif
}

// MARK: Camera

/// The 3D view's camera: an entity the view renders from, moved by the
/// view's gestures and by the camera state the host keeps.
@MainActor
final class BoardSceneCameraRig {
    let anchor = AnchorEntity(world: .zero)
    let camera = Entity()
    private(set) var orbit: BoardSceneOrbitCamera
    private(set) var projection: HorizontalBoardSceneProjection = .perspective
    /// The scene's size in millimetres, for the clipping planes.
    var sceneSize: Float = 100 {
        didSet { updateCamera() }
    }
    /// Called whenever the camera moves or changes, for the view to draw.
    var onChange: (() -> Void)?

    /// RealityKit's orthographic scale, like SceneKit's that camera states
    /// keep, is half the view's height.
    static let orthographicScaleFactor: Float = 1

    init() {
        let start = BoardSceneCameraMath.lookAt(position: SIMD3(-80, 80, 80), target: .zero, up: SIMD3(0, 1, 0))
        orbit = BoardSceneOrbitCamera(matrix: start, target: .zero)
        camera.name = "camera"
        anchor.addChild(camera)
        updateCamera()
    }

    /// Whether a camera state or a preset has put the camera anywhere yet.
    private(set) var isPlaced = false

    var state: HorizontalSceneCameraState {
        orbit.state
    }

    /// A camera nothing has placed starts at the default perspective, as
    /// far from the board as its size asks.
    func placeIfNeeded(board: HorizontalBoard) {
        guard !isPlaced else {
            return
        }
        apply(horizonSceneCameraState(for: .defaultPerspective, board: board))
    }

    /// Puts the camera where `state` says, keeping the projection.
    func apply(_ state: HorizontalSceneCameraState?) {
        guard let state, let matrix = state.matrix else {
            return
        }
        orbit = BoardSceneOrbitCamera(
            matrix: matrix,
            orthographicScale: projection == .orthogonal ? (state.orthographicScale ?? orbit.orthographicScale) : nil
        )
        isPlaced = true
        updateCamera()
    }

    /// Switches between perspective and orthographic, the orthographic
    /// camera starting at the board's default scale.
    func apply(_ projection: HorizontalBoardSceneProjection, board: HorizontalBoard) {
        let wasOrthographic = self.projection == .orthogonal
        self.projection = projection
        if projection == .orthogonal {
            if !wasOrthographic || orbit.orthographicScale == nil {
                orbit.orthographicScale = horizonSceneDefaultOrthographicScale(for: board)
            }
        } else {
            orbit.orthographicScale = nil
        }
        updateCamera()
    }

    func orbit(dx: Float, dy: Float) {
        orbit.orbit(dx: dx, dy: dy)
        updateCamera()
    }

    func pan(dx: Float, dy: Float) {
        orbit.pan(dx: dx, dy: dy)
        updateCamera()
    }

    func zoom(magnification: Float) {
        orbit.zoom(magnification: magnification)
        updateCamera()
    }

    /// The camera's ray through a point of a view `size` big, the point in
    /// that view's coordinates with y down.
    func ray(through point: CGPoint, in size: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let width = max(Float(size.width), 1)
        let height = max(Float(size.height), 1)
        let normalized = SIMD2(Float(point.x) / width * 2 - 1, 1 - Float(point.y) / height * 2)
        return BoardSceneCameraMath.ray(
            through: normalized,
            camera: orbit.matrix,
            aspect: width / height,
            orthographicScale: orbit.orthographicScale
        )
    }

    private func updateCamera() {
        camera.transform = Transform(matrix: orbit.matrix)
        let distance = orbit.orthographicScale.map { Float($0) * 2 + orbit.distance } ?? orbit.distance
        let planes = BoardSceneCameraMath.clippingPlanes(distance: distance, sceneSize: sceneSize)
        if let scale = orbit.orthographicScale {
            var component = OrthographicCameraComponent()
            component.near = 0.01
            component.far = planes.far + Float(scale) * 4
            component.scale = Float(scale) * Self.orthographicScaleFactor
            component.scaleDirection = .vertical
            camera.components.remove(PerspectiveCameraComponent.self)
            camera.components.set(component)
        } else {
            camera.components.remove(OrthographicCameraComponent.self)
            camera.components.set(PerspectiveCameraComponent(
                near: planes.near,
                far: planes.far,
                fieldOfViewInDegrees: BoardSceneCameraMath.fieldOfView,
                fieldOfViewOrientation: .vertical
            ))
        }
        onChange?()
    }
}

@MainActor
final class BoardSceneCoordinator {
    var cameraState: Binding<HorizontalSceneCameraState?>
    let sceneCache = BoardSceneSceneCache()
    var lastReportedState: HorizontalSceneCameraState?
    var lastAppliedProjection: HorizontalBoardSceneProjection?
    var lastHighlighted: Set<String>?
    var lastSelected: Set<String>?
    fileprivate var lastAppliedOptionsKey: BoardSceneAppliedOptionsKey?
    /// The view's values as of its last update, for a build that lands later.
    var latest: BoardSceneHostView?

    init(cameraState: Binding<HorizontalSceneCameraState?>) {
        self.cameraState = cameraState
    }

    func updateCameraState(_ state: HorizontalSceneCameraState?) {
        guard cameraState.wrappedValue != state else {
            return
        }
        lastReportedState = state
        cameraState.wrappedValue = state
    }
}

#if canImport(AppKit)
typealias BoardScenePlatformView = BoardSceneRenderView
#else
typealias BoardScenePlatformView = BoardSceneTouchRenderView
#endif

@MainActor
struct BoardSceneHostView {
    var board: HorizontalBoard
    var displayOptions: BoardDisplayOptions
    var backgroundColor: Color
    var copperColor: Color
    var layerColors: [Int: HorizontalRGBColor]
    var materialColors: HorizontalBoardColors
    var ignoresSceneMouseEvents: Bool
    var silkscreenClipping: HorizontalSilkscreenClipping? = nil
    var revision: Int = 0
    var highlightedComponentIDs: Set<String> = []
    var selectedComponentIDs: Set<String> = []
    var onSelectComponent: ((String?, Bool) -> Void)? = nil
    @Binding var cameraState: HorizontalSceneCameraState?
    @Binding var buildState: BoardSceneBuildState

    func makeCoordinator() -> BoardSceneCoordinator {
        BoardSceneCoordinator(cameraState: $cameraState)
    }

    private func makeView(context: Context) -> BoardScenePlatformView {
        let view = BoardScenePlatformView(frame: .zero)
        view.ignoresSceneMouseEvents = ignoresSceneMouseEvents
        view.onCameraStateChange = context.coordinator.updateCameraState
        view.applyBackground(backgroundColor, displayOptions: displayOptions)
        context.coordinator.latest = self
        attachSceneIfReady(to: view, coordinator: context.coordinator)
        return view
    }

    private func updateView(_ view: BoardScenePlatformView, context: Context) {
        context.coordinator.cameraState = $cameraState
        context.coordinator.latest = self
        view.ignoresSceneMouseEvents = ignoresSceneMouseEvents
        attachSceneIfReady(to: view, coordinator: context.coordinator)
    }

    /// Uses the built scene, or starts building it and comes back here on
    /// the main actor once it exists — configured from whatever this view's
    /// values are by then, not the ones at the time of the request.
    private func attachSceneIfReady(to view: BoardScenePlatformView, coordinator: BoardSceneCoordinator) {
        let cache = coordinator.sceneCache
        let scene = cache.scene(for: board, silkscreenClipping: silkscreenClipping, revision: revision) { [weak view, weak coordinator] scene in
            guard let view, let coordinator, let latest = coordinator.latest else {
                return
            }
            latest.configure(view, with: scene, coordinator: coordinator)
            latest.publishBuildState(coordinator.sceneCache.isBuilding ? .updating : .idle)
        }
        if let scene {
            configure(view, with: scene, coordinator: coordinator)
        }
        let desired: BoardSceneBuildState = cache.isBuilding ? (scene == nil ? .building : .updating) : .idle
        if buildState != desired {
            DispatchQueue.main.async { publishBuildState(desired) }
        }
    }

    private func publishBuildState(_ state: BoardSceneBuildState) {
        if buildState != state {
            buildState = state
        }
    }

    private func configure(_ view: BoardScenePlatformView, with scene: BoardSceneEntities, coordinator: BoardSceneCoordinator) {
        let sceneSwapped = view.shownScene !== scene
        #if canImport(AppKit)
        let appliedOptionsKey = BoardSceneAppliedOptionsKey(
            board: board, silkscreenClipping: silkscreenClipping, revision: revision,
            displayOptions: displayOptions, backgroundColor: backgroundColor, copperColor: copperColor,
            layerColors: layerColors, materialColors: materialColors, appearance: view.effectiveAppearance
        )
        #else
        let appliedOptionsKey = BoardSceneAppliedOptionsKey(
            board: board, silkscreenClipping: silkscreenClipping, revision: revision,
            displayOptions: displayOptions, backgroundColor: backgroundColor, copperColor: copperColor,
            layerColors: layerColors, materialColors: materialColors
        )
        #endif
        if sceneSwapped || coordinator.lastAppliedOptionsKey != appliedOptionsKey {
            scene.applyDisplayOptions(
                displayOptions,
                copperColor: copperColor,
                materialColors: materialColors,
                layerColors: layerColors
            )
            view.applyBackground(backgroundColor, displayOptions: displayOptions)
            coordinator.lastAppliedOptionsKey = appliedOptionsKey
            // The view draws only when asked: the scene's own changes are
            // asked for here, the camera's and the view's by themselves.
            view.surface.requestFrame()
        }
        if sceneSwapped {
            view.show(scene)
        }
        if sceneSwapped || coordinator.lastHighlighted != highlightedComponentIDs {
            scene.applyHighlight(componentIDs: highlightedComponentIDs)
            // The studio light goes down with the scene's own while a spot
            // is lit.
            view.surface.setEnvironmentExposure(scene.environmentExposure)
            coordinator.lastHighlighted = highlightedComponentIDs
            view.surface.requestFrame()
        }
        if sceneSwapped || coordinator.lastSelected != selectedComponentIDs {
            scene.applySelection(componentIDs: selectedComponentIDs)
            coordinator.lastSelected = selectedComponentIDs
            view.surface.requestFrame()
        }
        let projectionChanged = coordinator.lastAppliedProjection != displayOptions.threeDProjection
        coordinator.lastAppliedProjection = displayOptions.threeDProjection
        if sceneSwapped || projectionChanged {
            view.rig.apply(displayOptions.threeDProjection, board: board)
        }
        view.onCameraStateChange = coordinator.updateCameraState
        view.onPick = { [weak coordinator] componentID, extend in
            guard let latest = coordinator?.latest, let onSelectComponent = latest.onSelectComponent else {
                return
            }
            onSelectComponent(componentID, extend)
        }
        if sceneSwapped || projectionChanged || cameraState != coordinator.lastReportedState {
            view.rig.apply(cameraState)
            view.rig.placeIfNeeded(board: board)
            coordinator.lastReportedState = cameraState
        }
    }
}

#if canImport(AppKit)
extension BoardSceneHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> BoardSceneRenderView {
        makeView(context: context)
    }

    func updateNSView(_ nsView: BoardSceneRenderView, context: Context) {
        updateView(nsView, context: context)
    }
}

/// The Mac's 3D view: the scene drawn by `BoardSceneRenderSurface` when
/// something changes, with the camera driven the way SceneKit's camera
/// control drove it — drag to turn about what it looks at, right-, middle-
/// or option-drag and two-finger scroll to pan, pinch and the scroll wheel to
/// zoom — and a click that did not drag picking a part.
final class BoardSceneRenderView: NSView {
    private let metalLayer = CAMetalLayer()
    private(set) lazy var surface = BoardSceneRenderSurface(layer: metalLayer)
    var rig: BoardSceneCameraRig { surface.rig }
    var shownScene: BoardSceneEntities? { surface.shownScene }
    var ignoresSceneMouseEvents = false
    var onCameraStateChange: ((HorizontalSceneCameraState?) -> Void)?
    /// A click that did not drag: the component under it (nil for empty
    /// space or the board) and whether shift or command was down.
    var onPick: ((String?, Bool) -> Void)?

    private enum Drag {
        case orbit
        case pan
    }
    private var drag: Drag?
    private var clickStart: NSPoint?
    private var lastDragPoint: NSPoint?
    private var requestedBackgroundColor: Color = HorizontalDefaultTheme.background
    private var requestedDisplayOptions = BoardDisplayOptions()
    private var monitor: Any?
    // Coalesces high-frequency camera-state reports (one per scroll/zoom
    // tick) into a single binding write after the gesture settles. Without
    // this, every wheel tick pushed the binding, which cascaded into a full
    // SwiftUI update through `ProjectDocumentView` — making pan/zoom feel
    // sluggish even though the scene itself was static.
    private var pendingReportTimer: Timer?
    private static let reportSettleInterval: TimeInterval = 0.12
    private var displayLink: CADisplayLink?
    private let displayLinkTarget = BoardSceneDisplayLinkTarget()
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        configureView()
    }

    // A view let go of in its window never hears it is leaving: the link
    // and the observer go with it.
    isolated deinit {
        removeDisplayLink()
    }

    private func configureView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        displayLinkTarget.onStep = { [weak self] timestamp in
            self?.surface.step(at: timestamp)
        }
        surface.onActivityChange = { [weak self] in
            self?.updateDisplayLink()
        }
        updateDrawableSize()
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    override var isOpaque: Bool {
        true
    }

    func show(_ scene: BoardSceneEntities) {
        surface.show(scene)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        ignoresSceneMouseEvents ? nil : super.hitTest(point)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground(requestedBackgroundColor, displayOptions: requestedDisplayOptions)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground(requestedBackgroundColor, displayOptions: requestedDisplayOptions)
        configureMonitor()
        configureDisplayLink()
        updateDrawableSize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeMonitor()
            removeDisplayLink()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        surface.setSize(bounds.size, scale: scale)
    }

    /// A display link from the view's screen, which follows the window to
    /// another display, running only while the surface has a frame to draw.
    private func configureDisplayLink() {
        removeDisplayLink()
        guard let window else {
            return
        }
        let link = displayLink(target: displayLinkTarget, selector: #selector(BoardSceneDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateVisibility()
            }
        }
        updateVisibility()
        updateDisplayLink()
    }

    private func removeDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
    }

    private func updateVisibility() {
        surface.setVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    private func updateDisplayLink() {
        displayLink?.isPaused = !surface.isActive
    }

    /// The display link is running, for tests.
    var isDrawing: Bool {
        displayLink.map { !$0.isPaused } ?? false
    }

    func applyBackground(_ backgroundColor: Color, displayOptions: BoardDisplayOptions) {
        requestedBackgroundColor = backgroundColor
        requestedDisplayOptions = displayOptions
        let effectiveColor = horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions)
        let platformBackgroundColor = horizonScenePlatformColor(effectiveColor, resolvingAgainst: effectiveAppearance)
        surface.setBackground(platformBackgroundColor.cgColor)
    }

    private func configureMonitor() {
        removeMonitor()
        guard window != nil else {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handle(event)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !ignoresSceneMouseEvents else {
            return event
        }
        guard let window, event.window === window else {
            return event
        }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else {
            return event
        }
        apply(event)
        return nil
    }

    /// A scroll or a pinch over the view: a trackpad's two-finger scroll
    /// pans, a mouse wheel and a pinch zoom.
    private func apply(_ event: NSEvent) {
        if event.type == .magnify {
            guard event.magnification != 0 else {
                return
            }
            rig.zoom(magnification: Float(event.magnification))
            scheduleCameraStateReport()
            return
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        guard deltaX != 0 || deltaY != 0 else {
            return
        }
        if event.hasPreciseScrollingDeltas {
            rig.pan(dx: Float(deltaX), dy: Float(deltaY))
        } else {
            rig.zoom(magnification: Float(deltaY * 0.01))
        }
        scheduleCameraStateReport()
    }

    // The window's event monitor takes scrolls and pinches first; these see
    // only what reaches the view some other way.
    override func scrollWheel(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        apply(event)
    }

    override func magnify(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        apply(event)
    }

    /// The event's point in the view, y down.
    private func viewPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
    }

    private func beginDrag(_ mode: Drag, with event: NSEvent) {
        drag = mode
        let point = viewPoint(event)
        lastDragPoint = point
        clickStart = point
    }

    private func continueDrag(with event: NSEvent) {
        guard let drag, let last = lastDragPoint else {
            return
        }
        let point = viewPoint(event)
        lastDragPoint = point
        let dx = Float(point.x - last.x)
        let dy = Float(point.y - last.y)
        switch drag {
        case .orbit: rig.orbit(dx: dx, dy: dy)
        case .pan: rig.pan(dx: dx, dy: dy)
        }
    }

    private func endDrag(with event: NSEvent, picks: Bool) {
        drag = nil
        lastDragPoint = nil
        reportCameraState()
        guard picks, let start = clickStart else {
            clickStart = nil
            return
        }
        clickStart = nil
        // A click is a press and release within a few points; anything
        // further was a drag, which is the camera's.
        let end = viewPoint(event)
        guard hypot(end.x - start.x, end.y - start.y) < 4 else {
            return
        }
        let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        let ray = rig.ray(through: end, in: bounds.size)
        onPick?(shownScene?.componentID(along: ray), extend)
    }

    override func mouseDown(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        beginDrag(event.modifierFlags.contains(.option) ? .pan : .orbit, with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        beginDrag(.pan, with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        beginDrag(.pan, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        continueDrag(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        continueDrag(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        continueDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            clickStart = nil
            drag = nil
            return
        }
        endDrag(with: event, picks: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        endDrag(with: event, picks: false)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard !ignoresSceneMouseEvents else {
            return
        }
        endDrag(with: event, picks: false)
    }

    private func reportCameraState() {
        pendingReportTimer?.invalidate()
        pendingReportTimer = nil
        onCameraStateChange?(rig.state)
    }

    /// Restarts a single-shot timer that will push the latest camera
    /// transform up through the binding once the user stops scrolling /
    /// pinching. Called for every gesture tick; only the final tick's
    /// transform is reported, eliminating per-tick SwiftUI rebuilds.
    private func scheduleCameraStateReport() {
        pendingReportTimer?.invalidate()
        // Timer callbacks fire on the runloop they were scheduled on. We
        // schedule from the main runloop, so the closure runs on the main
        // thread — but Swift 6's strict concurrency can't see that, so we
        // hop explicitly through MainActor before touching `self`.
        pendingReportTimer = Timer.scheduledTimer(
            withTimeInterval: Self.reportSettleInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reportCameraState()
            }
        }
    }
}
#else
extension BoardSceneHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> BoardSceneTouchRenderView {
        makeView(context: context)
    }

    func updateUIView(_ uiView: BoardSceneTouchRenderView, context: Context) {
        updateView(uiView, context: context)
    }
}

/// The iPad's 3D view, drawn by `BoardSceneRenderSurface` when something
/// changes: one finger turns the camera about what it looks at, two pan, a
/// pinch zooms, and a tap picks a part.
final class BoardSceneTouchRenderView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    private(set) lazy var surface = BoardSceneRenderSurface(layer: layer as! CAMetalLayer)
    var rig: BoardSceneCameraRig { surface.rig }
    var shownScene: BoardSceneEntities? { surface.shownScene }
    private var displayLink: CADisplayLink?
    private let displayLinkTarget = BoardSceneDisplayLinkTarget()
    var ignoresSceneMouseEvents = false {
        didSet { isUserInteractionEnabled = !ignoresSceneMouseEvents }
    }
    var onCameraStateChange: ((HorizontalSceneCameraState?) -> Void)?
    /// A tap: the component under it (nil for empty space). Extending a
    /// selection is the second value; a tap never does.
    var onPick: ((String?, Bool) -> Void)?
    private var lastOrbitTranslation = CGPoint.zero
    private var lastPanTranslation = CGPoint.zero
    private let twoFingerGestures = TwoFingerGestures()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        configureView()
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    private func configureView() {
        isOpaque = true
        displayLinkTarget.onStep = { [weak self] timestamp in
            self?.surface.step(at: timestamp)
        }
        surface.onActivityChange = { [weak self] in
            self?.updateDisplayLink()
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        addGestureRecognizer(orbit)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.delegate = twoFingerGestures
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = twoFingerGestures
        addGestureRecognizer(pinch)
    }

    func show(_ scene: BoardSceneEntities) {
        surface.show(scene)
    }

    func applyBackground(_ backgroundColor: Color, displayOptions: BoardDisplayOptions) {
        let color = horizonScenePlatformColor(horizonSceneEffectiveBackgroundColor(backgroundColor, displayOptions: displayOptions))
        surface.setBackground(color.resolvedColor(with: traitCollection).cgColor)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            let link = CADisplayLink(target: displayLinkTarget, selector: #selector(BoardSceneDisplayLinkTarget.step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        updateDrawableSize()
        updateDisplayLink()
    }

    private func updateDrawableSize() {
        #if os(visionOS)
        surface.setSize(bounds.size, scale: traitCollection.displayScale)
        #else
        surface.setSize(bounds.size, scale: window?.screen.scale ?? traitCollection.displayScale)
        #endif
    }

    private func updateDisplayLink() {
        displayLink?.isPaused = !surface.isActive
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        let ray = rig.ray(through: recognizer.location(in: self), in: bounds.size)
        onPick?(shownScene?.componentID(along: ray), false)
    }

    @objc private func handleOrbit(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began {
            lastOrbitTranslation = .zero
        }
        rig.orbit(dx: Float(translation.x - lastOrbitTranslation.x), dy: Float(translation.y - lastOrbitTranslation.y))
        lastOrbitTranslation = translation
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onCameraStateChange?(rig.state)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began {
            lastPanTranslation = .zero
        }
        rig.pan(dx: Float(translation.x - lastPanTranslation.x), dy: Float(translation.y - lastPanTranslation.y))
        lastPanTranslation = translation
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onCameraStateChange?(rig.state)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .changed, recognizer.scale > 0 {
            rig.zoom(magnification: Float(log(recognizer.scale)))
            recognizer.scale = 1
        }
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onCameraStateChange?(rig.state)
        }
    }
}

/// Lets two fingers pan and pinch at once, as they did in SceneKit.
private final class TwoFingerGestures: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer)
            && (gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer)
    }
}
#endif

/// The display link's target: the link keeps its target alive, so it holds
/// this rather than the view.
@MainActor
final class BoardSceneDisplayLinkTarget: NSObject {
    var onStep: ((CFTimeInterval) -> Void)?

    @objc func step(_ link: CADisplayLink) {
        onStep?(link.timestamp)
    }
}

// MARK: Offscreen

/// Renders a scene without a view, through RealityKit's own renderer: for
/// diagnosing a scene without the app, and for tests.
@MainActor
enum BoardSceneOffscreenRenderer {
    enum RenderError: Error {
        case noDevice
        case noTexture
        case noImage
    }

    static func render(
        _ scene: BoardSceneEntities,
        camera state: HorizontalSceneCameraState,
        projection: HorizontalBoardSceneProjection,
        size: CGSize,
        background: BoardSceneColor
    ) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let rig = BoardSceneCameraRig()
        rig.sceneSize = Float(max(scene.boardWidth, scene.boardDepth))
        rig.apply(projection, board: scene.board)
        rig.apply(state)
        rig.placeIfNeeded(board: scene.board)

        let renderer = try RealityRenderer()
        renderer.entities.append(scene.root)
        renderer.entities.append(rig.anchor)
        defer {
            renderer.entities.removeAll()
        }
        renderer.activeCamera = rig.camera
        renderer.cameraSettings.colorBackground = .color(background.cgColor)
        renderer.lighting.resource = BoardSceneEnvironment.resource()
        renderer.lighting.intensityExponent = BoardSceneEnvironment.intensityExponent + scene.environmentExposure

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.noTexture
        }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        // Let animations started by the display options (explode) finish.
        try renderer.update(1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in
                    continuation.resume()
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // RealityKit renders in Display P3; the image says so, then becomes
        // sRGB like everything else the app compares it with.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let renderedSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let outputSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: renderedSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw RenderError.noImage
        }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw RenderError.noImage
        }
        return image
    }
}

#if canImport(AppKit)
extension BoardSceneFactory {
    /// A rendered frame of the full scene from a preset, with a description
    /// of what it holds and how long each step took: for diagnosing a scene
    /// without the app.
    struct DebugSnapshot {
        var image: NSImage
        var report: String
    }

    @MainActor
    static func debugSnapshot(
        for board: HorizontalBoard,
        size: CGSize,
        displayOptions: BoardDisplayOptions = BoardDisplayOptions(),
        silkscreenClipping: HorizontalSilkscreenClipping? = nil,
        preset: HorizontalBoard3DViewPreset = .defaultPerspective
    ) async -> DebugSnapshot {
        func milliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let describeStart = DispatchTime.now().uptimeNanoseconds
        let description = await Task.detached(priority: .userInitiated) {
            describeScene(for: board, silkscreenClipping: silkscreenClipping)
        }.value
        let describeMilliseconds = milliseconds(since: describeStart)
        let entitiesStart = DispatchTime.now().uptimeNanoseconds
        let scene = BoardSceneEntities(description: description)
        let entitiesMilliseconds = milliseconds(since: entitiesStart)
        let applyStart = DispatchTime.now().uptimeNanoseconds
        scene.applyDisplayOptions(
            displayOptions,
            copperColor: Color(red: 0.72, green: 0.45, blue: 0.2),
            materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            layerColors: [:]
        )
        let applyMilliseconds = milliseconds(since: applyStart)
        let stats = scene.statistics
        var report = [
            "describe \(describeMilliseconds) ms, entities \(entitiesMilliseconds) ms, apply display options \(applyMilliseconds) ms",
            "meshes=\(stats.meshes) vertices=\(stats.vertices) triangles=\(stats.triangles)",
            "models: instances=\(stats.modelInstances) draws=\(stats.modelDraws); vias: instances=\(stats.viaInstances) draws=\(stats.viaDraws)",
        ]
        let renderStart = DispatchTime.now().uptimeNanoseconds
        do {
            let image = try await BoardSceneOffscreenRenderer.render(
                scene,
                camera: horizonSceneCameraState(for: preset, board: board),
                projection: preset.projection,
                size: size,
                background: BoardSceneColor(HorizontalDefaultTheme.backgroundNS)
            )
            report.append("render \(milliseconds(since: renderStart)) ms")
            return DebugSnapshot(image: NSImage(cgImage: image, size: size), report: report.joined(separator: "\n"))
        } catch {
            report.append("render failed: \(error)")
            return DebugSnapshot(image: NSImage(size: size), report: report.joined(separator: "\n"))
        }
    }
}
#endif
