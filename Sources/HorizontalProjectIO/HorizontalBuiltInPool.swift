import Foundation

/// The Horizon pool items Horizontal ships, for a project that no pool it can
/// reach has them for: horizon-pool's Circular via and its tented sibling, so
/// that a board has a via to drop with no pool installed.
///
/// They are horizon-pool's own files, unchanged and under its uuids, so a
/// board made without horizon-pool names the item it would have named with
/// it, and takes the pool's own once there is one. A board copies the one it
/// uses into its project pool's cache, as Horizon copies an item it takes from
/// a pool, so the project carries it and Horizon opens it without the pool.
///
/// The files are under horizon-pool's licence, CC BY-SA 4.0, not Horizontal's:
/// they sit apart from the code, in `Resources/horizon-pool`, with that licence
/// and their attribution.
public enum HorizontalBuiltInPool {
    /// horizon-pool's uuid: the pool these items are from.
    public static let horizonPoolUUID = "6d752bc3-29b3-45df-8cf2-1e3aacefbcc6"

    /// The padstacks shipped, by uuid, at their paths in horizon-pool.
    public static let padstackPaths: [String: String] = [
        HorizontalProjectArchive.horizonPoolCircularVia: "padstacks/via-round.json",
        HorizontalProjectArchive.horizonPoolTentedCircularVia: "padstacks/via-round-tented.json"
    ]

    /// The shipped file of a padstack, nil for one Horizontal doesn't ship or
    /// a build without the files.
    public static func padstackURL(_ uuid: String) -> URL? {
        guard let path = padstackPaths[uuid.lowercased()], let directory else {
            return nil
        }
        let url = directory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The padstack's file, byte for byte as horizon-pool has it.
    public static func padstackData(_ uuid: String) -> Data? {
        padstackURL(uuid).flatMap { try? Data(contentsOf: $0) }
    }

    /// `Resources/horizon-pool` in the resource bundle SwiftPM and Xcode build
    /// for this module, wherever the binary keeps it: in the app's resources,
    /// beside a test bundle, a command line tool or a dylib. `Bundle.module`
    /// finds the same bundle, but stops the process where there is none, as
    /// for a dylib copied without it; this finds no items there instead.
    static let directory: URL? = {
        let bundleName = "HorizontalNative_HorizontalProjectIO.bundle"
        let finder = Bundle(for: BundleFinder.self)
        var places = [Bundle.main.resourceURL, finder.resourceURL, Bundle.main.bundleURL, finder.bundleURL.deletingLastPathComponent()]
        // A dylib's bundle is its host's, so where it was loaded from says
        // where it was built.
        var image = Dl_info()
        if dladdr(#dsohandle, &image) != 0, let path = image.dli_fname {
            places.append(URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent())
        }
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent(bundleName, isDirectory: true)),
               let url = bundle.url(forResource: "horizon-pool", withExtension: nil) {
                return url
            }
        }
        return nil
    }()
}

private final class BundleFinder {}
