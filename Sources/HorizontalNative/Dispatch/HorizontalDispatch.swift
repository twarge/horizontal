import Foundation

/// JSON-RPC 2.0 dispatch over the loaded model.
///
/// One entry point serves every headless front end: the Python package
/// (through HorizontalPy's C symbol), the `horizontal` command line tool, the
/// MCP server built on the Python package, and the app's own live channel.
/// Requests are `{"jsonrpc": "2.0", "id": …, "method": …, "params": {…}}`
/// objects; the method table lives in `HorizontalDispatchMethods`.
public enum HorizontalDispatch {
    public static let apiVersion = 1

    /// JSON text in, JSON text out. Never throws: failures come back as
    /// JSON-RPC error objects so the caller has a single code path.
    public static func call(_ requestJSON: String) -> String {
        let response: JSONDictionary
        if let data = requestJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let request = object as? JSONDictionary {
            response = call(request)
        } else {
            response = errorResponse(id: nil, code: .parseError, message: "Request is not a JSON object.")
        }
        return serialize(response, pretty: false)
    }

    static func call(_ request: JSONDictionary) -> JSONDictionary {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return errorResponse(id: id, code: .invalidRequest, message: "Request has no method.")
        }
        let params = request["params"] as? JSONDictionary ?? [:]
        guard let handler = HorizontalDispatchMethods.handler(named: method) else {
            return errorResponse(
                id: id,
                code: .methodNotFound,
                message: "Unknown method \(method).",
                data: ["methods": HorizontalDispatchMethods.all.map(\.name)]
            )
        }
        do {
            let result = try HorizontalDispatchSession.shared.perform { session in
                try handler(session, params)
            }
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": HorizontalDispatchJSON.sanitized(result)]
        } catch let error as HorizontalDispatchError {
            return errorResponse(id: id, code: error.code, message: error.message, data: error.data)
        } catch {
            return errorResponse(id: id, code: .applicationError, message: error.localizedDescription)
        }
    }

    static func errorResponse(
        id: Any?,
        code: HorizontalDispatchError.Code,
        message: String,
        data: JSONDictionary? = nil
    ) -> JSONDictionary {
        var error: JSONDictionary = ["code": code.rawValue, "message": message]
        if let data {
            error["data"] = data
        }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error]
    }

    static func serialize(_ object: JSONDictionary, pretty: Bool) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        if let data = try? JSONSerialization.data(withJSONObject: HorizontalDispatchJSON.sanitized(object), options: options),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Response could not be serialized."}}"#
    }
}

/// Carries non-Sendable values into a `MainActor.assumeIsolated` block that
/// the caller has already verified runs on the main thread (the live
/// handlers, which the live server calls from the main queue).
final class HorizontalUnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

struct HorizontalDispatchError: Error {
    enum Code: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        case applicationError = -32000
        case notFound = -32001
    }

    var code: Code
    var message: String
    var data: JSONDictionary? = nil

    static func invalidParams(_ message: String) -> Self {
        Self(code: .invalidParams, message: message)
    }

    static func notFound(_ message: String) -> Self {
        Self(code: .notFound, message: message)
    }

    static func failed(_ message: String) -> Self {
        Self(code: .applicationError, message: message)
    }
}

/// Makes result values safe for `JSONSerialization`: non-finite doubles
/// become null, optionals unwrap or become null, containers are walked.
enum HorizontalDispatchJSON {
    static func sanitized(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else {
                return NSNull()
            }
            return sanitized(child.value)
        }
        switch value {
        case let dictionary as JSONDictionary:
            return dictionary.mapValues { sanitized($0) }
        case let array as [Any]:
            return array.map { sanitized($0) }
        case let double as Double:
            return double.isFinite ? double : NSNull()
        case let float as Float:
            return float.isFinite ? Double(float) : NSNull()
        case let cgFloat as CGFloat:
            return cgFloat.isFinite ? Double(cgFloat) : NSNull()
        case is String, is Int, is Bool, is NSNull, is Int64, is Int32, is UInt, is NSNumber:
            return value
        case let url as URL:
            return url.path
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return String(describing: value)
        }
    }

    /// Nanometres to millimetres, rounded to a tenth of a micron.
    static func mm(_ nanometres: Double) -> Double {
        (nanometres / 1_000_000 * 10_000).rounded() / 10_000
    }

    /// Horizon stores angles as 1/65536 of a turn.
    static func degrees(_ angle: Int) -> Double {
        (Double(angle) * 360 / 65_536 * 100).rounded() / 100
    }

    static func point(_ point: HorizontalPoint) -> JSONDictionary {
        ["x_mm": mm(point.x), "y_mm": mm(point.y)]
    }

    static func rect(_ rect: HorizontalRect) -> JSONDictionary {
        [
            "min_x_mm": mm(rect.minX),
            "min_y_mm": mm(rect.minY),
            "max_x_mm": mm(rect.maxX),
            "max_y_mm": mm(rect.maxY),
            "width_mm": mm(rect.maxX - rect.minX),
            "height_mm": mm(rect.maxY - rect.minY)
        ]
    }
}
