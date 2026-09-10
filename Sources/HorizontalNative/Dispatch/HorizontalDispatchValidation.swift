import Foundation
import CoreFoundation

enum HorizontalDispatchValidation {
    static func validate(method: String, params: JSONDictionary) throws {
        guard let descriptor = HorizontalDispatchMethods.all.first(where: { $0.name == method }) else { return }
        let common: Set<String> = ["include_metadata", "expected_revision", "operation_id", "plan_digest", "deadline_unix_ms"]
        let allowed = Set(descriptor.params.keys).union(common)
        let unknown = Set(params.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw HorizontalDispatchError.invalidParams("Unknown parameters: \(unknown.sorted().joined(separator: ", ")).") }
        let integers: Set<String> = ["handle", "sheet", "max_pixels", "limit", "layer"]
        let numbers: Set<String> = ["dpi", "margin_mm", "deadline_unix_ms"]
        let booleans: Set<String> = ["include_metadata", "include_unconnected", "include_no_populate", "dry_run",
                                     "mirrored", "redo"]
        let objects: Set<String> = ["region", "options"]
        let arrays: Set<String> = ["ops", "items", "pool_items", "components", "nets", "layers", "sections", "panes"]
        for (key, value) in params {
            if integers.contains(key) { try number(value, key: key, integer: true) }
            else if numbers.contains(key) { try number(value, key: key) }
            else if booleans.contains(key) { try boolean(value, key: key) }
            else if objects.contains(key) {
                guard value is JSONDictionary else { throw HorizontalDispatchError.invalidParams("\(key) must be an object.") }
            } else if arrays.contains(key) {
                guard let array = value as? [Any], array.count <= 10_000 else { throw HorizontalDispatchError.invalidParams("\(key) must be an array of at most 10000 entries.") }
                if ["ops", "items", "pool_items"].contains(key), !array.allSatisfy({ $0 is JSONDictionary }) {
                    throw HorizontalDispatchError.invalidParams("\(key) entries must be objects.")
                }
                if !["ops", "items", "pool_items"].contains(key), !array.allSatisfy({ $0 is String }) {
                    throw HorizontalDispatchError.invalidParams("\(key) entries must be strings.")
                }
            } else if !(value is String) { throw HorizontalDispatchError.invalidParams("\(key) must be a string.") }
        }
        if let dpi = params.double("dpi"), !(1...2400).contains(dpi) { throw HorizontalDispatchError.invalidParams("dpi must be between 1 and 2400.") }
        if let pixels = params.int("max_pixels"), !(1...8192).contains(pixels) { throw HorizontalDispatchError.invalidParams("max_pixels must be between 1 and 8192.") }
        if let margin = params.double("margin_mm"), !(0...1000).contains(margin) { throw HorizontalDispatchError.invalidParams("margin_mm must be between 0 and 1000.") }
        // Each method clamps to its own documented maximum; this is the outer bound.
        if let limit = params.int("limit"), !(1...5000).contains(limit) { throw HorizontalDispatchError.invalidParams("limit must be between 1 and 5000.") }
        if let region = params.dictionary("region") {
            let keys: Set<String> = ["min_x_mm", "min_y_mm", "max_x_mm", "max_y_mm"]
            guard Set(region.keys) == keys else { throw HorizontalDispatchError.invalidParams("region requires exactly min_x_mm, min_y_mm, max_x_mm, max_y_mm.") }
            for (key, value) in region { try number(value, key: key) }
            guard region.double("min_x_mm")! < region.double("max_x_mm")!, region.double("min_y_mm")! < region.double("max_y_mm")! else {
                throw HorizontalDispatchError.invalidParams("region must have positive width and height.")
            }
        }
        if method == "get_net" { try exactlyOne(params, keys: ["name", "id"]) }
        if method == "get_component" { try exactlyOne(params, keys: ["refdes", "id"]) }
        if method == "zoom_to" { try exactlyOne(params, keys: ["refdes", "net"]) }
    }

    static func number(_ value: Any, key: String, integer: Bool = false) throws {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              !integer || n.doubleValue.rounded() == n.doubleValue else {
            throw HorizontalDispatchError.invalidParams("\(key) must be a finite \(integer ? "integer" : "number").")
        }
    }

    static func checkDeadline(_ params: JSONDictionary) throws {
        if let deadline = params.double("deadline_unix_ms"), Date().timeIntervalSince1970 * 1000 >= deadline {
            throw HorizontalDispatchError(code: .timeout, message: "Request expired before execution or commit.")
        }
    }

    static func boolean(_ value: Any, key: String) throws {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw HorizontalDispatchError.invalidParams("\(key) must be a Boolean.")
        }
    }

    static func exactlyOne(_ params: JSONDictionary, keys: [String]) throws {
        let selected = keys.filter { params[$0] != nil }
        guard selected.count == 1, let text = params[selected[0]] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass exactly one non-empty selector: \(keys.joined(separator: ", ")).")
        }
        if selected[0] == "id", UUID(uuidString: text) == nil { throw HorizontalDispatchError.invalidParams("id must be a UUID.") }
    }

    static func component(_ selector: String, index: HorizontalDesignIndex) throws -> HorizontalDesignComponent {
        let matches = index.sortedComponents.filter { $0.id.caseInsensitiveCompare(selector) == .orderedSame || $0.refdes.caseInsensitiveCompare(selector) == .orderedSame }
        guard let first = matches.first else { throw HorizontalDispatchError.notFound("No component \(selector).") }
        guard matches.count == 1 else { throw HorizontalDispatchError.ambiguous("Component selector is ambiguous; use a UUID.", candidates: matches.map(\.id)) }
        return first
    }

    static func net(_ selector: String, index: HorizontalDesignIndex) throws -> HorizontalDesignNet {
        guard !selector.isEmpty else { throw HorizontalDispatchError.invalidParams("Use the UUID to select an unnamed net.") }
        let matches = index.sortedNets.filter { $0.id.caseInsensitiveCompare(selector) == .orderedSame || $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        guard let first = matches.first else { throw HorizontalDispatchError.notFound("No net \(selector).") }
        guard matches.count == 1 else { throw HorizontalDispatchError.ambiguous("Net selector is ambiguous; use a UUID.", candidates: matches.map(\.id)) }
        return first
    }

    static func sheet(_ params: JSONDictionary, index: HorizontalDesignIndex, defaultFirst: Bool = false) throws -> HorizontalDesignSheet? {
        let selectors = ["sheet", "name", "sheet_id"].filter { params[$0] != nil }
        guard selectors.count <= 1 else { throw HorizontalDispatchError.invalidParams("Use only one sheet selector.") }
        if selectors.isEmpty && params["block_id"] == nil { return defaultFirst ? index.sheets.first : nil }
        let found = index.sheets.filter { sheet in
            (params.string("block_id").map { sheet.blockID?.lowercased() == $0.lowercased() } ?? true)
            && (params.int("sheet").map { sheet.index == $0 } ?? true)
            && (params.string("name").map { sheet.name.caseInsensitiveCompare($0) == .orderedSame } ?? true)
            && (params.string("sheet_id").map { sheet.id.caseInsensitiveCompare($0) == .orderedSame } ?? true)
        }
        guard !found.isEmpty else { throw HorizontalDispatchError.notFound("No sheet matches the selector.") }
        guard found.count == 1 else { throw HorizontalDispatchError.ambiguous("Sheet selector is ambiguous; use block_id and sheet_id.", candidates: found.map { "\($0.blockID ?? "")/\($0.id)" }) }
        return found[0]
    }
}
