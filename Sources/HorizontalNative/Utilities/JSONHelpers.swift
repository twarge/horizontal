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
