import Foundation
import HorizontalProjectIO

/// The padstacks a package keeps of its own, in `padstacks/` beside its
/// `package.json`, found by the uuid each carries.
///
/// Horizon's pool update reads every `.json` in a package's `padstacks/` and
/// its database finds a padstack by uuid, whatever its file is called.
/// Horizon's project pool caches one as `<uuid>.json`
/// (`ProjectPool::get_filename`); a package made in a pool names it for what
/// it is (`padstacks/EP.json`), and Horizontal's cache import keeps that name.
/// The board loader and the package editor both resolve a pad's padstack
/// here, so each finds it under either name.
enum HorizontalPackagePadstacks {
    struct Padstack {
        /// Lowercased.
        var id: String
        var url: URL
        var json: JSONDictionary
    }

    /// The padstack's JSON, or nil when the package has none of that uuid.
    /// A file named for the uuid is taken as it is; any other is read for the
    /// uuid it carries.
    static func json(_ padstackID: String, packageDirectory: URL) -> JSONDictionary? {
        let id = padstackID.lowercased()
        let named = directory(of: packageDirectory).appendingPathComponent("\(id).json")
        if let json = try? JSONHelper.loadDictionary(from: named) {
            return json
        }
        return padstacks(packageDirectory: packageDirectory).first { $0.id == id }?.json
    }

    /// Every padstack the package keeps, once each, by file name. Of two
    /// files carrying one uuid, the one named for it, else the first.
    static func padstacks(packageDirectory: URL) -> [Padstack] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory(of: packageDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var found = [Padstack]()
        var indexByID = [String: Int]()
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard let json = try? JSONHelper.loadDictionary(from: url),
                  let id = json.string("uuid")?.lowercased(),
                  isPadstack(json) else {
                continue
            }
            let padstack = Padstack(id: id, url: url, json: json)
            if let index = indexByID[id] {
                if url.deletingPathExtension().lastPathComponent.lowercased() == id {
                    found[index] = padstack
                }
            } else {
                indexByID[id] = found.count
                found.append(padstack)
            }
        }
        return found
    }

    private static func directory(of packageDirectory: URL) -> URL {
        packageDirectory.appendingPathComponent("padstacks", isDirectory: true)
    }

    /// A padstack's `type` is "padstack", or for an older one its own kind
    /// ("top", "through"); only another pool item kind rules a file out.
    private static func isPadstack(_ json: JSONDictionary) -> Bool {
        guard let type = json.string("type"), type != HorizontalPoolItemCategory.padstack.rawValue else {
            return true
        }
        return HorizontalPoolItemCategory(rawValue: type) == nil
    }
}
