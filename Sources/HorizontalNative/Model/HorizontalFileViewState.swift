import Foundation

struct HorizontalWindowSize: Codable, Equatable {
    var width: Double
    var height: Double

    var isValid: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

struct HorizontalSceneCameraState: Codable, Equatable {
    var transform: [Float]
    var orthographicScale: Double?

    init(transform: [Float], orthographicScale: Double? = nil) {
        self.transform = transform
        self.orthographicScale = orthographicScale
    }

    var isValid: Bool {
        let scaleIsValid = orthographicScale.map { $0.isFinite && $0 > 0 } ?? true
        return transform.count == 16 && transform.allSatisfy(\.isFinite) && scaleIsValid
    }
}

enum HorizontalWorkspaceRightSidebar: String, Codable, Equatable {
    case selection
    case export
    case rulesResults
}

struct HorizontalFileViewState: Codable, Equatable {
    var visiblePanes: Set<HorizontalPane>
    var showsNavigatorSidebar: Bool
    var showsSelectionSidebar: Bool
    var rightSidebarPane: HorizontalWorkspaceRightSidebar?
    var windowSize: HorizontalWindowSize?
    var schematicViewport: CanvasViewport
    var boardViewport: CanvasViewport
    var threeDCameraState: HorizontalSceneCameraState?
    var schematicDisplayOptions: SchematicDisplayOptions
    var boardDisplayOptions: BoardDisplayOptions

    init(
        visiblePanes: Set<HorizontalPane>,
        showsNavigatorSidebar: Bool,
        showsSelectionSidebar: Bool,
        rightSidebarPane: HorizontalWorkspaceRightSidebar? = nil,
        windowSize: HorizontalWindowSize? = nil,
        schematicViewport: CanvasViewport = CanvasViewport(),
        boardViewport: CanvasViewport = CanvasViewport(),
        threeDCameraState: HorizontalSceneCameraState? = nil,
        schematicDisplayOptions: SchematicDisplayOptions,
        boardDisplayOptions: BoardDisplayOptions
    ) {
        self.visiblePanes = visiblePanes
        self.showsNavigatorSidebar = showsNavigatorSidebar
        self.showsSelectionSidebar = showsSelectionSidebar
        self.rightSidebarPane = rightSidebarPane ?? (showsSelectionSidebar ? .selection : nil)
        self.windowSize = windowSize
        self.schematicViewport = schematicViewport
        self.boardViewport = boardViewport
        self.threeDCameraState = threeDCameraState
        self.schematicDisplayOptions = schematicDisplayOptions
        self.boardDisplayOptions = boardDisplayOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visiblePanes = try container.decodeIfPresent(Set<HorizontalPane>.self, forKey: .visiblePanes) ?? Self.default.visiblePanes
        showsNavigatorSidebar = try container.decodeIfPresent(Bool.self, forKey: .showsNavigatorSidebar) ?? Self.default.showsNavigatorSidebar
        showsSelectionSidebar = try container.decodeIfPresent(Bool.self, forKey: .showsSelectionSidebar) ?? Self.default.showsSelectionSidebar
        rightSidebarPane = try container.decodeIfPresent(HorizontalWorkspaceRightSidebar.self, forKey: .rightSidebarPane)
            ?? (showsSelectionSidebar ? .selection : nil)
        windowSize = try container.decodeIfPresent(HorizontalWindowSize.self, forKey: .windowSize)
        schematicViewport = try container.decodeIfPresent(CanvasViewport.self, forKey: .schematicViewport) ?? Self.default.schematicViewport
        boardViewport = try container.decodeIfPresent(CanvasViewport.self, forKey: .boardViewport) ?? Self.default.boardViewport
        threeDCameraState = try container.decodeIfPresent(HorizontalSceneCameraState.self, forKey: .threeDCameraState)
        schematicDisplayOptions = try container.decodeIfPresent(SchematicDisplayOptions.self, forKey: .schematicDisplayOptions) ?? Self.default.schematicDisplayOptions
        boardDisplayOptions = try container.decodeIfPresent(BoardDisplayOptions.self, forKey: .boardDisplayOptions) ?? Self.default.boardDisplayOptions
    }

    static let `default` = HorizontalFileViewState(
        visiblePanes: [.schematic, .board],
        showsNavigatorSidebar: true,
        // Closed on first open: a freshly opened project has no selection, so
        // the pane would only ever say "No selection" while taking 340pt off
        // the canvas. Projects that were saved with it open keep it open —
        // this is only the default for a project with no stored view state.
        showsSelectionSidebar: false,
        rightSidebarPane: nil,
        windowSize: nil,
        schematicViewport: CanvasViewport(),
        boardViewport: CanvasViewport(),
        threeDCameraState: nil,
        schematicDisplayOptions: SchematicDisplayOptions(),
        boardDisplayOptions: BoardDisplayOptions()
    )
}

@MainActor
final class HorizontalFileViewStateStore {
    static let shared = HorizontalFileViewStateStore()

    private static let defaultsPrefix = "fileViewState.v1."

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for fileURL: URL) -> HorizontalFileViewState? {
        guard let data = defaults.data(forKey: key(for: fileURL)) else {
            return nil
        }
        return try? decoder.decode(HorizontalFileViewState.self, from: data)
    }

    func save(_ state: HorizontalFileViewState, for fileURL: URL) {
        guard let data = try? encoder.encode(state) else {
            return
        }
        defaults.set(data, forKey: key(for: fileURL))
    }

    private func key(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let encoded = Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return Self.defaultsPrefix + encoded
    }
}
