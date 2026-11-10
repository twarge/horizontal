import Foundation
import HorizontalProjectIO

/// A new, empty Horizon pool, made as Horizon's pool manager makes one
/// (`PoolProjectManagerViewCreatePool::create`): into an empty folder, a
/// `pool.json` (`PoolInfo::save`), a directory for each kind of item and one
/// for 3D models, each holding an empty `.keep` so git keeps it, and the
/// `.gitignore` Horizon writes. Horizon builds its `pool.db` itself the first
/// time it opens the pool, and this app needs no database: its index is the
/// scan `HorizontalPoolLibrary` keeps.
enum HorizontalPoolCreation {
    enum Failure: LocalizedError, Equatable {
        case emptyName
        case notEmpty(String)
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                "The pool needs a name."
            case .notEmpty(let path):
                "“\(path)” is not empty. A new pool goes into an empty folder, as Horizon makes one."
            case .notADirectory(let path):
                "“\(path)” is a file, not a folder."
            }
        }
    }

    /// The item directories, in Horizon's `IPool::type_names` order (the map
    /// is keyed by object type; the order makes no difference on disk), and
    /// `3d_models`.
    static let directoryNames = [
        "units", "symbols", "entities", "padstacks", "packages", "parts", "frames", "decals", "3d_models",
    ]

    /// Horizon's `.gitignore` for a new pool, byte for byte (it writes no
    /// final newline).
    static let gitignore = "*.db\n*.db-*\ntmp/*.json\n3d_models/local\n*.imp_meta\n*.autosave\n*.bak"

    /// The keys `PoolInfo::save` writes for a pool with no default via or
    /// frame. `version` is written only when the pool names a default frame,
    /// which a new one doesn't.
    static func poolJSON(name: String, uuid: String, includedPools: [String] = []) -> [String: Any] {
        [
            "uuid": uuid.lowercased(),
            "default_via": HorizontalProjectArchive.nullUUID,
            "default_frame": HorizontalProjectArchive.nullUUID,
            "name": name,
            "type": "pool",
            "pools_included": includedPools.map { $0.lowercased() },
        ]
    }

    /// `pool.json` as Horizon writes it: nlohmann's `dump(4)`, keys in
    /// order, no final newline — which is what the app's Horizon writer
    /// produces for every file.
    static func poolJSONData(name: String, uuid: String, includedPools: [String] = []) throws -> Data {
        try HorizontalHorizonJSONWriter.data(poolJSON(name: name, uuid: uuid, includedPools: includedPools))
    }

    /// Where a pool chosen by folder goes: into the folder itself when it is
    /// empty (Horizon's rule), else into a new folder named after the pool
    /// inside it, numbered if that name is taken.
    static func destination(inChosenFolder folder: URL, name: String) -> URL {
        if isEmptyDirectory(folder) {
            return folder
        }
        let base = HorizontalPoolItemFactory.slug(name, fallback: "pool")
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    /// Makes the pool at `directory`, which must be missing or empty, and
    /// returns its `pool.json`. A failure part way leaves what was written,
    /// as Horizon does; the error says what went wrong.
    @discardableResult
    static func create(
        at directory: URL,
        name: String,
        uuid: String = UUID().uuidString.lowercased(),
        includedPools: [String] = []
    ) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Failure.emptyName
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw Failure.notADirectory(directory.path)
            }
            guard try fileManager.contentsOfDirectory(atPath: directory.path).allSatisfy({ $0 == ".DS_Store" }) else {
                throw Failure.notEmpty(directory.path)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let poolJSONURL = directory.appendingPathComponent("pool.json")
        try poolJSONData(name: name, uuid: uuid, includedPools: includedPools).write(to: poolJSONURL, options: .atomic)
        for name in directoryNames {
            let subdirectory = directory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: false)
            try Data().write(to: subdirectory.appendingPathComponent(".keep"))
        }
        try Data(gitignore.utf8).write(to: directory.appendingPathComponent(".gitignore"))
        return poolJSONURL
    }

    /// Makes the pool and registers it, so it is browsed with the others and
    /// the New menu can save items into it.
    @MainActor
    @discardableResult
    static func createAndRegister(
        at directory: URL,
        name: String,
        includedPools: [String] = [],
        registry: HorizontalPoolRegistry = .shared
    ) throws -> HorizontalRegisteredPool {
        try create(at: directory, name: name, includedPools: includedPools)
        guard registry.addPool(at: directory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.appendingPathComponent("pool.json").path])
        }
        HorizontalPoolLibrary.invalidateCache()
        return HorizontalPoolRegistryStore.poolInfo(at: directory.standardizedFileURL)
    }

    /// Whether a folder has nothing in it, hidden files counted (Horizon's
    /// check lists every entry). `.DS_Store`, which Finder leaves in a folder
    /// it has only shown, doesn't count.
    static func isEmptyDirectory(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.allSatisfy { $0 == ".DS_Store" }
    }
}
