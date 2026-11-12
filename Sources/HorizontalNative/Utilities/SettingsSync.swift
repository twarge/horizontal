import Foundation

/// What `SettingsSync` asks of iCloud's key-value store, so a test can stand
/// in for it.
protocol SettingsSyncStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: SettingsSyncStore {}

/// Carries the user's preferences between their devices through iCloud's
/// key-value store.
///
/// Settings stay in `UserDefaults`, where the app reads them; this only
/// copies a fixed list of keys in both directions. What describes one device
/// or one document rather than the person stays put: bookmarks and pool
/// paths, window and column layout, per-document view state, the theme, the
/// read-only lock, the live server and the distributors' accounts.
///
/// A setting put back to its default is a key removed, and the removal
/// travels too: `mirrored` remembers which keys this device and the cloud
/// both held, so a key gone from one side was taken away there and is not
/// merely one that side never had.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    /// Posted, with the `UserDefaults` as its object, after another device's
    /// choices were written there, for what read its settings at launch.
    static let didPullNotification = Notification.Name("SettingsSync.didPull")

    static let syncedKeys: [String] = HorizontalAppearanceSettings.syncedDefaultsKeys + [
        HorizontalPlaneFillDefaults.updatesAutomaticallyKey,
        HorizontalRulesCheckDefaults.checksAutomaticallyKey,
        HorizontalSpotlightFraming.framesEveryViewKey,
        HorizontalDrawingToolSettings.rectanglePlacementModeKey,
        // `HorizontalBoardToolSettings`: how the router is driven. The widths
        // and diameters beside them belong to the board last routed.
        "boardTool.cornerStyle",
        "boardTool.routerMode",
        "boardTool.routerShove",
        "boardTool.removeLoops",
        "boardTool.startsOnCopper",
    ]

    /// `ubiquityIdentityToken`, archived: which iCloud account, if any.
    typealias Account = @MainActor () -> Data?

    private static let mirroredDefaultsKey = "SettingsSync.mirroredKeys"
    private static let accountDefaultsKey = "SettingsSync.account"
    private static let pushDelay = 0.5

    private let defaults: UserDefaults
    private let store: any SettingsSyncStore
    private let domain: String
    private let account: Account
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// The synced keys this device and the cloud both held when last compared.
    private var mirrored: Set<String> = []
    /// Set while this writes `UserDefaults` itself, which is not the user's
    /// doing and must not start a push half way through a pull.
    private var isApplying = false
    private var pushScheduled = false

    init(
        defaults: UserDefaults = .standard,
        store: any SettingsSyncStore = NSUbiquitousKeyValueStore.default,
        domain: String = Bundle.main.bundleIdentifier ?? "",
        account: @escaping Account = SettingsSync.currentAccount
    ) {
        self.defaults = defaults
        self.store = store
        self.domain = domain
        self.account = account
    }

    /// Begins syncing. Without the iCloud entitlement, or signed out of
    /// iCloud, the store simply never reports or accepts anything.
    func start() {
        guard !started else { return }
        started = true
        HorizontalAppearanceSettings.seedDefaultsBeforeSync(defaults: defaults)
        mirrored = Set(defaults.stringArray(forKey: Self.mirroredDefaultsKey) ?? [])
        forgetMirroredKeysIfAccountChanged()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.storeChanged(reason: reason, keys: keys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        })
        store.synchronize()
        pull(keys: Self.syncedKeys, takesRemovals: true)
        push()
    }

    /// The cloud's copy changed: another device's doing, the first download,
    /// or another account signing in.
    func storeChanged(reason: Int?, keys: [String]?) {
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            return
        case NSUbiquitousKeyValueStoreAccountChange:
            // Another account's store is not this one with keys removed.
            mirrored = []
            forgetMirroredKeysIfAccountChanged()
            pull(keys: Self.syncedKeys, takesRemovals: false)
        case NSUbiquitousKeyValueStoreInitialSyncChange:
            pull(keys: keys ?? Self.syncedKeys, takesRemovals: false)
        default:
            pull(keys: keys ?? Self.syncedKeys, takesRemovals: true)
        }
        push()
    }

    /// Cloud to device, for keys the cloud has a value for; and, where
    /// `takesRemovals`, a key the cloud held and no longer does is removed
    /// here as it was there.
    private func pull(keys: [String], takesRemovals: Bool) {
        let synced = Set(Self.syncedKeys)
        var changed = false
        isApplying = true
        for key in keys where synced.contains(key) {
            if let value = store.object(forKey: key) as? NSObject {
                mirrored.insert(key)
                guard (defaults.object(forKey: key) as? NSObject) != value else { continue }
                defaults.set(value, forKey: key)
                changed = true
            } else if takesRemovals, mirrored.remove(key) != nil, defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                changed = true
            }
        }
        saveMirrored()
        isApplying = false
        if changed {
            NotificationCenter.default.post(name: Self.didPullNotification, object: defaults)
        }
    }

    /// Device to cloud, for keys the user has actually set. A registered
    /// default is not a choice and must not overwrite one made elsewhere. A
    /// key both sides held that is gone from here was reset, and goes from
    /// the cloud.
    func push() {
        let chosen = defaults.persistentDomain(forName: domain) ?? [:]
        for key in Self.syncedKeys {
            if let value = chosen[key] as? NSObject {
                if (store.object(forKey: key) as? NSObject) != value {
                    store.set(value, forKey: key)
                }
                // Mirrored only once the store holds it. A build without
                // the iCloud entitlement has a store that drops every write,
                // and a key it never took must not read at the next launch
                // as one the cloud took away.
                if (store.object(forKey: key) as? NSObject) == value {
                    mirrored.insert(key)
                } else {
                    mirrored.remove(key)
                }
            } else if mirrored.remove(key) != nil {
                store.removeObject(forKey: key)
            }
        }
        isApplying = true
        saveMirrored()
        isApplying = false
    }

    /// `UserDefaults` reports every write, a slider's each step among them,
    /// and most are not to a synced key: one push follows the last of a run.
    private func schedulePush() {
        guard !isApplying, !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.pushScheduled = false
                self?.push()
            }
        }
    }

    private func saveMirrored() {
        let keys = mirrored.sorted()
        guard keys != (defaults.stringArray(forKey: Self.mirroredDefaultsKey) ?? []) else { return }
        defaults.set(keys, forKey: Self.mirroredDefaultsKey)
    }

    /// `mirrored` describes one account's store. Signed out, or signed in to
    /// another, an absent key says nothing about a reset.
    private func forgetMirroredKeysIfAccountChanged() {
        let current = account()
        guard current != defaults.data(forKey: Self.accountDefaultsKey) else { return }
        mirrored = []
        isApplying = true
        if let current {
            defaults.set(current, forKey: Self.accountDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.accountDefaultsKey)
        }
        saveMirrored()
        isApplying = false
    }

    static func currentAccount() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        // A probe: a token that will not archive reads as signed out, and
        // then only removals stop travelling.
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }
}
