import Foundation

typealias JSONDictionary = [String: Any]

enum HorizontalJSONError: LocalizedError {
    case invalidRoot(URL)
    case missingValue(String, URL)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let url):
            return "\(url.lastPathComponent) is not a JSON object."
        case .missingValue(let key, let url):
            return "\(url.lastPathComponent) is missing \(key)."
        }
    }
}

enum JSONHelper {
    static func loadDictionary(from url: URL) throws -> JSONDictionary {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? JSONDictionary else {
            throw HorizontalJSONError.invalidRoot(url)
        }
        return dictionary
    }

    /// The same parse for bytes already in memory (a document's archive).
    static func loadDictionary(from data: Data) throws -> JSONDictionary {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? JSONDictionary else {
            throw HorizontalJSONError.invalidRoot(URL(fileURLWithPath: "document.json"))
        }
        return dictionary
    }

    /// Which pool item kind a JSON file holds, from its `type`, or nil for
    /// anything else (a project file's type is "project", a pool's "pool").
    static func poolItemCategory(in data: Data) -> HorizontalPoolItemCategory? {
        guard let json = try? loadDictionary(from: data),
              let type = json.string("type") else {
            return nil
        }
        return HorizontalPoolItemCategory(rawValue: type)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? Double {
            return Int(value)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double {
            return value
        }
        if let value = self[key] as? Int {
            return Double(value)
        }
        return nil
    }

    func dictionary(_ key: String) -> JSONDictionary? {
        self[key] as? JSONDictionary
    }

    func dictionaryMap(_ key: String) -> [String: JSONDictionary] {
        guard let map = self[key] as? [String: Any] else {
            return [:]
        }

        return map.reduce(into: [String: JSONDictionary]()) { result, item in
            if let value = item.value as? JSONDictionary {
                result[item.key] = value
            }
        }
    }

    func dictionaryArray(_ key: String) -> [JSONDictionary] {
        self[key] as? [JSONDictionary] ?? []
    }

    func doubleArray(_ key: String) -> [Double] {
        guard let values = self[key] as? [Any] else {
            return []
        }

        return values.map(JSONHelper.doubleValue)
    }

    func point(_ key: String) -> HorizontalPoint? {
        guard let values = self[key] as? [Any], values.count >= 2 else {
            return nil
        }

        return HorizontalPoint(x: JSONHelper.doubleValue(values[0]), y: JSONHelper.doubleValue(values[1]))
    }

    func horizonTextOrigin(_ key: String = "origin") -> HorizontalTextOrigin {
        HorizontalTextOrigin(rawValue: string(key) ?? "") ?? .center
    }

    func horizonTextFont(_ key: String = "font") -> HorizontalTextFont {
        HorizontalTextFont(rawValue: string(key) ?? "") ?? .simplex
    }
}

extension JSONHelper {
    static func doubleValue(_ value: Any) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        return 0
    }
}
