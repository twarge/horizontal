import Combine
import Foundation

/// Persistent defaults for the board track-drawing tool, edited in the route
/// inspector and with the in-route keys (`w`, `c`). Backed by
/// UserDefaults so choices survive across routes and launches. Widths are
/// stored in the board's internal nanometers.
@MainActor
final class HorizontalBoardToolSettings: ObservableObject {
    static let defaultViaDiameter = 500_000.0
    static let defaultViaHoleDiameter = 200_000.0

    /// Explicit track width (nm). When nil, a route continues the width of
    /// the track it starts on, else takes the track width rules'
    /// (`HorizontalRouteWidth`). Set by `w` and the inspector.
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

    /// A route that leaves its net's copper and comes back to it replaces the
    /// stretch between, as Horizon's router removes loops
    /// (`BoardTrackLoops`). On unless turned off.
    @Published var removeLoops: Bool {
        didSet { defaults.set(removeLoops, forKey: Self.removeLoopsKey) }
    }

    /// A route starts only on copper on its layer: a pad, a track or a via
    /// (`BoardTrackRouting.copperStart`). ⌘-click starts one anywhere. On
    /// unless turned off.
    @Published var startsOnCopper: Bool {
        didSet { defaults.set(startsOnCopper, forKey: Self.startsOnCopperKey) }
    }

    /// Via diameter (nm), which makes a route's via its own. When nil, the
    /// route's via takes the via rules' (`HorizontalBoard.routeVia`).
    @Published var viaDiameter: Double? {
        didSet { persist(viaDiameter, forKey: Self.viaDiameterKey) }
    }

    /// Via hole diameter (nm), as `viaDiameter`.
    @Published var viaHoleDiameter: Double? {
        didSet { persist(viaHoleDiameter, forKey: Self.viaHoleKey) }
    }

    /// The tune tool's meander (`HorizontalMeander.Settings`): the largest
    /// amplitude and the spacing, nanometres, the corners and the style.
    @Published var meanderAmplitude: Double {
        didSet { defaults.set(meanderAmplitude, forKey: Self.meanderAmplitudeKey) }
    }

    @Published var meanderSpacing: Double {
        didSet { defaults.set(meanderSpacing, forKey: Self.meanderSpacingKey) }
    }

    @Published var meanderCorner: HorizontalMeander.Corner {
        didSet { defaults.set(meanderCorner.rawValue, forKey: Self.meanderCornerKey) }
    }

    @Published var meanderStyle: HorizontalMeander.Style {
        didSet { defaults.set(meanderStyle.rawValue, forKey: Self.meanderStyleKey) }
    }

    /// The length a tune makes its net, nanometres: typed with Return or in
    /// the inspector. Nil for the Length Tuning window's reference, as
    /// Horizon's tune tools take it.
    @Published var tuneTarget: Double? {
        didSet { persist(tuneTarget, forKey: Self.tuneTargetKey) }
    }

    var meanderSettings: HorizontalMeander.Settings {
        var settings = HorizontalMeander.Settings()
        settings.amplitude = meanderAmplitude
        settings.spacing = meanderSpacing
        settings.corner = meanderCorner
        settings.style = meanderStyle
        return settings
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        explicitTrackWidth = Self.optionalDouble(defaults, forKey: Self.trackWidthKey)
        cornerStyle = (defaults.string(forKey: Self.cornerStyleKey))
            .flatMap(BoardTrackCornerStyle.init(rawValue:)) ?? .ninety
        routerMode = defaults.bool(forKey: Self.routerModeKey)
        routerShove = defaults.bool(forKey: Self.routerShoveKey)
        removeLoops = defaults.object(forKey: Self.removeLoopsKey) as? Bool ?? true
        startsOnCopper = defaults.object(forKey: Self.startsOnCopperKey) as? Bool ?? true
        viaDiameter = Self.optionalDouble(defaults, forKey: Self.viaDiameterKey)
        viaHoleDiameter = Self.optionalDouble(defaults, forKey: Self.viaHoleKey)
        let meander = HorizontalMeander.Settings()
        meanderAmplitude = Self.optionalDouble(defaults, forKey: Self.meanderAmplitudeKey) ?? meander.amplitude
        meanderSpacing = Self.optionalDouble(defaults, forKey: Self.meanderSpacingKey) ?? meander.spacing
        meanderCorner = defaults.string(forKey: Self.meanderCornerKey).flatMap(HorizontalMeander.Corner.init(rawValue:)) ?? meander.corner
        meanderStyle = defaults.string(forKey: Self.meanderStyleKey).flatMap(HorizontalMeander.Style.init(rawValue:)) ?? meander.style
        tuneTarget = Self.optionalDouble(defaults, forKey: Self.tuneTargetKey)
    }

    /// Resolved via geometry given a board's via template (template values fill
    /// in anything the user hasn't overridden).
    func resolvedViaDiameter(template: HorizontalBoardViaTemplate?) -> Double {
        viaDiameter ?? template?.diameter ?? Self.defaultViaDiameter
    }

    func resolvedViaHoleDiameter(template: HorizontalBoardViaTemplate?) -> Double {
        viaHoleDiameter ?? template?.holeDiameter ?? Self.defaultViaHoleDiameter
    }

    /// The route inspector's Rules / Custom, nil for the rules'. These set a
    /// property only when it changes: an @Published property publishes on
    /// every set, the value it already has too.
    func setExplicitTrackWidth(_ width: Double?) {
        if explicitTrackWidth != width {
            explicitTrackWidth = width
        }
    }

    func setVia(diameter: Double?, holeDiameter: Double?) {
        if viaDiameter != diameter {
            viaDiameter = diameter
        }
        if viaHoleDiameter != holeDiameter {
            viaHoleDiameter = holeDiameter
        }
    }

    /// A route started on copper sizes itself from the rules again: on a pad
    /// its width and via both, on a track its width, which continues the
    /// track's (`HorizontalRouteWidth.start`) while the via stays as it is.
    /// Started anywhere else, a custom width and via hold.
    func startRoute(onPad: Bool, onTrack: Bool) {
        if onPad || onTrack {
            setExplicitTrackWidth(nil)
        }
        if onPad {
            setVia(diameter: nil, holeDiameter: nil)
        }
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
    private static let removeLoopsKey = "boardTool.removeLoops"
    private static let startsOnCopperKey = "boardTool.startsOnCopper"
    private static let viaDiameterKey = "boardTool.viaDiameterNM"
    private static let viaHoleKey = "boardTool.viaHoleDiameterNM"
    private static let meanderAmplitudeKey = "boardTool.meanderAmplitudeNM"
    private static let meanderSpacingKey = "boardTool.meanderSpacingNM"
    private static let meanderCornerKey = "boardTool.meanderCorner"
    private static let meanderStyleKey = "boardTool.meanderStyle"
    private static let tuneTargetKey = "boardTool.tuneTargetNM"
}
