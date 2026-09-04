import Foundation
import HorizontalProjectIO

enum HorizontalPoolItemFactoryError: LocalizedError {
    case fileExists(URL)
    case invalidLocation(String)
    case notAPackage(URL)

    var errorDescription: String? {
        switch self {
        case .fileExists(let url):
            "“\(url.lastPathComponent)” already exists."
        case .invalidLocation(let message):
            message
        case .notAPackage(let url):
            "“\(url.lastPathComponent)” is not a package directory."
        }
    }
}

/// Creating and duplicating pool items the way Horizon's pool manager does:
/// the seeding rules of `pool_notebook_*.cpp` and the file layout rules of
/// `Pool::check_filename`. Models are written with the Horizon-exact writer.
enum HorizontalPoolItemFactory {
    // MARK: - New items

    static func newUUID() -> String {
        UUID().uuidString.lowercased()
    }

    static func newUnit() -> HorizontalPoolUnit {
        HorizontalPoolUnit(uuid: newUUID(), name: "")
    }

    /// An entity on its own has no gates; one made for a unit gets that
    /// unit's name and a "Main" gate on it (`handle_create_entity_for_unit`).
    static func newEntity(for unit: HorizontalPoolUnit? = nil) -> HorizontalPoolEntity {
        guard let unit else {
            return HorizontalPoolEntity(uuid: newUUID(), name: "")
        }
        let gateID = newUUID()
        return HorizontalPoolEntity(
            uuid: newUUID(),
            name: unit.name,
            manufacturer: unit.manufacturer,
            gates: [gateID: HorizontalEntityGate(id: gateID, name: "Main", unitID: unit.uuid)]
        )
    }

    /// `handle_create_symbol_for_unit`: named after the unit, no pins yet.
    static func newSymbol(for unit: HorizontalPoolUnit) -> HorizontalPoolSymbol {
        HorizontalPoolSymbol(uuid: newUUID(), name: unit.name, unitID: unit.uuid)
    }

    /// `handle_create_part`: MPN and manufacturer seeded from the entity.
    static func newPart(entity: HorizontalPoolEntity, packageID: String) -> HorizontalPoolPartItem {
        HorizontalPoolPartItem(
            uuid: newUUID(),
            entityID: entity.uuid,
            packageID: packageID,
            mpn: entity.name,
            manufacturer: entity.manufacturer
        )
    }

    /// `handle_create_part_from_part`: a part based on another, every
    /// attribute and the tags inherited.
    static func newPart(basedOn base: HorizontalPoolPartItem) -> HorizontalPoolPartItem {
        var part = HorizontalPoolPartItem(uuid: newUUID(), entityID: "", packageID: "")
        part.entityID = nil
        part.packageID = nil
        part.baseID = base.uuid
        for kind in HorizontalPartAttributeKind.allCases {
            part.attributes[kind] = HorizontalPartAttribute(inherited: true, value: base.attribute(kind).value)
        }
        part.inheritTags = true
        return part
    }

    static func newPackage() -> HorizontalPoolPackage {
        HorizontalPoolPackage(uuid: newUUID(), name: "")
    }

    static func newPadstack(type: HorizontalPadstackType = .top) -> HorizontalPoolPadstack {
        HorizontalPoolPadstack(uuid: newUUID(), name: "", type: type)
    }

    static func newFrame() -> HorizontalPoolFrame {
        HorizontalPoolFrame(uuid: newUUID(), name: "")
    }

    static func newDecal() -> HorizontalPoolDecal {
        HorizontalPoolDecal(uuid: newUUID(), name: "")
    }

    // MARK: - Duplicates

    /// `handle_duplicate_item`: the same item under a fresh uuid, its name
    /// (a part's MPN) suffixed " (Copy)". Packages go through
    /// `duplicatePackage`, which also copies their directory.
    static func duplicate(_ model: HorizontalPoolItemModel) -> HorizontalPoolItemModel {
        let uuid = newUUID()
        switch model {
        case .unit(var unit):
            unit.uuid = uuid
            unit.name += " (Copy)"
            return .unit(unit)
        case .entity(var entity):
            entity.uuid = uuid
            entity.name += " (Copy)"
            return .entity(entity)
        case .part(var part):
            part.uuid = uuid
            var mpn = part.attribute(.mpn)
            mpn.value += " (Copy)"
            mpn.inherited = false
            part.attributes[.mpn] = mpn
            return .part(part)
        case .symbol(var symbol):
            symbol.uuid = uuid
            symbol.name += " (Copy)"
            return .symbol(symbol)
        case .package(var package):
            package.uuid = uuid
            package.name += " (Copy)"
            return .package(package)
        case .padstack(var padstack):
            padstack.uuid = uuid
            padstack.name += " (Copy)"
            return .padstack(padstack)
        case .frame(var frame):
            frame.uuid = uuid
            frame.name += " (Copy)"
            return .frame(frame)
        case .decal(var decal):
            decal.uuid = uuid
            decal.name += " (Copy)"
            return .decal(decal)
        }
    }

    /// `DuplicatePartWidget::duplicate_package`: the package directory is
    /// copied whole (3D models and all), the package gets a fresh uuid and
    /// `name`, and every package-local padstack gets a fresh uuid with the
    /// pads re-pointed at it. Returns the new package.json URL.
    @discardableResult
    static func duplicatePackage(
        from packageJSONURL: URL,
        to newDirectory: URL,
        name: String
    ) throws -> URL {
        let sourceDirectory = packageJSONURL.deletingLastPathComponent()
        guard packageJSONURL.lastPathComponent == "package.json" else {
            throw HorizontalPoolItemFactoryError.notAPackage(packageJSONURL)
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: newDirectory.path) else {
            throw HorizontalPoolItemFactoryError.fileExists(newDirectory)
        }
        try fileManager.createDirectory(at: newDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceDirectory, to: newDirectory)

        var package = try HorizontalPoolPackage(json: JSONHelper.loadDictionary(from: packageJSONURL))
        package.uuid = newUUID()
        package.name = name

        let padstackDirectory = newDirectory.appendingPathComponent("padstacks", isDirectory: true)
        try fileManager.createDirectory(at: padstackDirectory, withIntermediateDirectories: true)
        let padstackURLs = (try? fileManager.contentsOfDirectory(at: padstackDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in padstackURLs where url.pathExtension.lowercased() == "json" {
            guard var padstack = try? HorizontalPoolPadstack(json: JSONHelper.loadDictionary(from: url)) else {
                continue
            }
            let oldID = padstack.uuid.lowercased()
            padstack.uuid = newUUID()
            for (padID, pad) in package.pads where pad.padstackID.lowercased() == oldID {
                package.pads[padID]?.padstackID = padstack.uuid
            }
            try HorizontalHorizonJSONWriter.data(padstack.json()).write(to: url, options: [.atomic])
        }

        let newPackageURL = newDirectory.appendingPathComponent("package.json")
        try HorizontalHorizonJSONWriter.data(package.json()).write(to: newPackageURL, options: [.atomic])
        return newPackageURL
    }

    // MARK: - Locations

    /// The pool subdirectory a kind lives in.
    static func directoryName(for category: HorizontalPoolItemCategory) -> String {
        switch category {
        case .unit: "units"
        case .entity: "entities"
        case .part: "parts"
        case .symbol: "symbols"
        case .package: "packages"
        case .padstack: "padstacks"
        case .frame: "frames"
        case .decal: "decals"
        }
    }

    /// A file-system-friendly spelling of a name: lowercase, words joined
    /// with dashes, nothing but letters, digits, dash, underscore and dot.
    static func slug(_ name: String, fallback: String) -> String {
        let lowered = name.lowercased()
        var result = ""
        var lastWasSeparator = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "_" {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result.isEmpty ? fallback : result
    }

    /// Where a new item of this kind would go by default: the kind's
    /// directory in the pool, named after the item (packages get a directory
    /// with a `package.json` inside; a symbol made for a unit mirrors the
    /// unit's path under `symbols/`, as upstream suggests).
    static func suggestedURL(
        for model: HorizontalPoolItemModel,
        in poolURL: URL,
        mirroring referenceURL: URL? = nil
    ) -> URL {
        let category = model.category
        let directory = poolURL.appendingPathComponent(directoryName(for: category), isDirectory: true)
        let base = slug(model.name, fallback: category.singularTitle.lowercased())
        if category == .package {
            return directory.appendingPathComponent(base, isDirectory: true).appendingPathComponent("package.json")
        }
        if let referenceURL,
           let relative = relativePath(of: referenceURL.deletingLastPathComponent(), within: poolURL),
           let firstComponent = relative.split(separator: "/").first,
           let referenceCategory = HorizontalPoolItemCategory.allCases.first(where: { directoryName(for: $0) == firstComponent }),
           referenceCategory != category {
            // symbols/<unit-relative-dir>/<unit-basename>.json
            let subdirectory = relative.split(separator: "/").dropFirst().joined(separator: "/")
            var target = directory
            if !subdirectory.isEmpty {
                target = target.appendingPathComponent(subdirectory, isDirectory: true)
            }
            return target.appendingPathComponent(referenceURL.lastPathComponent)
        }
        return directory.appendingPathComponent(base + ".json")
    }

    /// Where a duplicate would go: next to the original, `-copy` inserted
    /// before the extension (`DuplicateUnitWidget::insert_filename`).
    static func suggestedDuplicateURL(of itemURL: URL) -> URL {
        if itemURL.lastPathComponent == "package.json" {
            let directory = itemURL.deletingLastPathComponent()
            return directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + "-copy", isDirectory: true)
                .appendingPathComponent("package.json")
        }
        let base = itemURL.deletingPathExtension().lastPathComponent + "-copy"
        return itemURL.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("json")
    }

    /// A location no existing file claims: appends `-2`, `-3`… as needed.
    static func availableURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        let isPackage = url.lastPathComponent == "package.json"
        let probe = isPackage ? url.deletingLastPathComponent() : url
        guard fileManager.fileExists(atPath: probe.path) else {
            return url
        }
        var counter = 2
        while true {
            if isPackage {
                let directory = probe.deletingLastPathComponent()
                    .appendingPathComponent(probe.lastPathComponent + "-\(counter)", isDirectory: true)
                if !fileManager.fileExists(atPath: directory.path) {
                    return directory.appendingPathComponent("package.json")
                }
            } else {
                let base = probe.deletingPathExtension().lastPathComponent + "-\(counter)"
                let next = probe.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("json")
                if !fileManager.fileExists(atPath: next.path) {
                    return next
                }
            }
            counter += 1
        }
    }

    /// `Pool::check_filename`: units under `units/`, parts under `parts/`…;
    /// a package is `packages/<dir>/package.json`; a padstack is either
    /// `padstacks/…/*.json` or `packages/<dir>/padstacks/*.json`. Returns a
    /// message when the location is wrong.
    static func locationProblem(
        for url: URL,
        category: HorizontalPoolItemCategory,
        in poolURL: URL
    ) -> String? {
        guard let relative = relativePath(of: url, within: poolURL) else {
            return "The file must be inside the pool folder “\(poolURL.lastPathComponent)”."
        }
        let components = relative.split(separator: "/").map(String.init)
        let expected = directoryName(for: category)
        switch category {
        case .package:
            guard components.count == 3, components[0] == "packages", components[2] == "package.json" else {
                return "A package must be saved as packages/<name>/package.json."
            }
        case .padstack:
            let inPool = components.count >= 2 && components[0] == "padstacks"
            let inPackage = components.count == 4 && components[0] == "packages" && components[2] == "padstacks"
            guard inPool || inPackage else {
                return "A padstack must be saved under padstacks/ or inside a package's padstacks/ folder."
            }
        default:
            guard components.count >= 2, components[0] == expected else {
                return "\(category.singularTitle.capitalized)s must be saved under \(expected)/."
            }
        }
        guard url.pathExtension.lowercased() == "json" else {
            return "The file name must end in .json."
        }
        return nil
    }

    static func relativePath(of url: URL, within poolURL: URL) -> String? {
        let base = poolURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Writing

    /// Writes a model to `url` in Horizon's format, creating the directories
    /// on the way (and a package's `padstacks/` folder). Refuses to replace
    /// an existing file unless asked.
    @discardableResult
    static func write(_ model: HorizontalPoolItemModel, to url: URL, replacingExisting: Bool = false) throws -> Data {
        let fileManager = FileManager.default
        if !replacingExisting, fileManager.fileExists(atPath: url.path) {
            throw HorizontalPoolItemFactoryError.fileExists(url)
        }
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if model.category == .package, url.lastPathComponent == "package.json" {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("padstacks", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let data = try HorizontalHorizonJSONWriter.data(model.json())
        try data.write(to: url, options: [.atomic])
        return data
    }

    /// The library row a freshly written item would scan as, so the browser
    /// can open it before its next rescan.
    static func libraryItem(
        for model: HorizontalPoolItemModel,
        at url: URL,
        poolURL: URL,
        poolName: String
    ) -> HorizontalPoolLibraryItem {
        let key = model.category.rawValue + "|" + model.uuid.lowercased()
        let detail: String
        switch model {
        case .part(let part): detail = part.attribute(.manufacturer).value
        case .padstack(let padstack): detail = padstack.type.rawValue
        default: detail = ""
        }
        return HorizontalPoolLibraryItem(
            id: poolURL.standardizedFileURL.path + "|" + key,
            uuid: model.uuid.lowercased(),
            name: model.name,
            detail: detail,
            tags: "",
            category: model.category,
            poolName: poolName,
            poolURL: poolURL.standardizedFileURL,
            url: url
        )
    }
}
