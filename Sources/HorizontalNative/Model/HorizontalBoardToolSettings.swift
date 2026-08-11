import Combine
import Foundation

/// Persistent defaults for the board track-drawing tool, edited via the
/// settings popover (`S`) and the in-route keys (`w`, `c`). Backed by
/// UserDefaults so choices survive across routes and launches. Widths are
/// stored in the board's internal nanometers.
@MainActor
final class HorizontalBoardToolSettings: ObservableObject {
    static let defaultViaDiameter = 500_000.0
    static let defaultViaHoleDiameter = 200_000.0

    /// Explicit track width (nm). When nil, the tool falls back to the
    /// width-under-cursor / net heuristic. Set by `w` and the popover.
    @Published var explicitTrackWidth: Double? {
        didSet { persist(explicitTrackWidth, forKey: Self.trackWidthKey) }
    }

    /// Corner geometry applied to new routes. Cycled by `c`.
    @Published var cornerStyle: BoardTrackCornerStyle {
        didSet { defaults.set(cornerStyle.rawValue, forKey: Self.cornerStyleKey) }
    }

    /// Use the interactive push-and-shove autorouter (vendored KiCad PNS) rather
    /// than the manual click-to-route tool. macOS only; ignored where the router
    /// isn't built. Off by default, so the proven manual path stays the default.
    @Published var routerMode: Bool {
        didSet { defaults.set(routerMode, forKey: Self.routerModeKey) }
    }

    /// When the autorouter is on, let it shove existing copper aside; otherwise
    /// it only walks around obstacles.
    @Published var routerShove: Bool {
        didSet { defaults.set(routerShove, forKey: Self.routerShoveKey) }
    }

    /// Via diameter (nm). When nil, the board's via template diameter is used.
    @Published var viaDiameter: Double? {
        didSet { persist(viaDiameter, forKey: Self.viaDiameterKey) }
    }

    /// Via hole diameter (nm). When nil, the board's via template hole is used.
    @Published var viaHoleDiameter: Double? {
        didSet { persist(viaHoleDiameter, forKey: Self.viaHoleKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        explicitTrackWidth = Self.optionalDouble(defaults, forKey: Self.trackWidthKey)
        cornerStyle = (defaults.string(forKey: Self.cornerStyleKey))
            .flatMap(BoardTrackCornerStyle.init(rawValue:)) ?? .ninety
        routerMode = defaults.bool(forKey: Self.routerModeKey)
        routerShove = defaults.bool(forKey: Self.routerShoveKey)
        viaDiameter = Self.optionalDouble(defaults, forKey: Self.viaDiameterKey)
        viaHoleDiameter = Self.optionalDouble(defaults, forKey: Self.viaHoleKey)
    }

    /// Resolved via geometry given a board's via template (template values fill
    /// in anything the user hasn't overridden).
    func resolvedViaDiameter(template: HorizontalBoardViaTemplate?) -> Double {
        viaDiameter ?? template?.diameter ?? Self.defaultViaDiameter
    }

    func resolvedViaHoleDiameter(template: HorizontalBoardViaTemplate?) -> Double {
        viaHoleDiameter ?? template?.holeDiameter ?? Self.defaultViaHoleDiameter
    }

    private func persist(_ value: Double?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func optionalDouble(_ defaults: UserDefaults, forKey key: String) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }

    private static let trackWidthKey = "boardTool.trackWidthNM"
    private static let cornerStyleKey = "boardTool.cornerStyle"
    private static let routerModeKey = "boardTool.routerMode"
    private static let routerShoveKey = "boardTool.routerShove"
    private static let viaDiameterKey = "boardTool.viaDiameterNM"
    private static let viaHoleKey = "boardTool.viaHoleDiameterNM"
}
