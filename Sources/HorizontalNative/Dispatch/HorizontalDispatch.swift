import Foundation
import HorizontalProjectIO

/// JSON-RPC 2.0 dispatch over the loaded model.
///
/// One entry point serves every headless front end: the Python package
/// (through HorizontalPy's C symbol), the `horizontal` command line tool, the
/// MCP server built on the Python package, and the app's own live channel.
/// Requests are `{"jsonrpc": "2.0", "id": …, "method": …, "params": {…}}`
/// objects; the method table lives in `HorizontalDispatchMethods`.
public enum HorizontalDispatch {
    public static let apiVersion = 2

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

    static func call(_ request: JSONDictionary, in dispatchSession: HorizontalDispatchSession = .shared) -> JSONDictionary {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return errorResponse(id: id, code: .invalidRequest, message: "Request has no method.")
        }
        guard request["jsonrpc"] as? String == "2.0", request["params"] == nil || request["params"] is JSONDictionary else {
            return errorResponse(id: id, code: .invalidRequest, message: "Expected JSON-RPC 2.0 and object params.")
        }
        var params = request["params"] as? JSONDictionary ?? [:]
        if let deadline = request["deadline_unix_ms"] { params["deadline_unix_ms"] = deadline }
        guard let handler = HorizontalDispatchMethods.handler(named: method) else {
            return errorResponse(
                id: id,
                code: .methodNotFound,
                message: "Unknown method \(method).",
                data: ["methods": HorizontalDispatchMethods.all.map(\.name)]
            )
        }
        do {
            let result: Any = try dispatchSession.perform { session -> Any in
                try HorizontalDispatchValidation.validate(method: method, params: params)
                try HorizontalDispatchValidation.checkDeadline(params)
                let result = try handler(session, params)
                if params.bool("include_metadata") == true, let handle = params.int("handle"), method != "close_project" {
                    return ["data": result, "meta": try session.entry(handle: handle).metadata] as JSONDictionary
                }
                return result
            }
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": HorizontalDispatchJSON.sanitized(result)]
        } catch let error as HorizontalDispatchError {
            return errorResponse(id: id, code: error.code, message: error.message, data: error.data)
        } catch let error as HorizontalProjectTransaction.Failure {
            let code: HorizontalDispatchError.Code
            switch error {
            case .timeout: code = .timeout
            case .conflict: code = .staleRevision
            case .recoveryRequired: code = .recoveryRequired
            }
            let typed = HorizontalDispatchError(code: code, message: error.localizedDescription)
            return errorResponse(id: id, code: code, message: typed.message, data: typed.data)
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
        var structured = HorizontalDispatchError(code: code, message: message).data
        if let data {
            if data["code"] == nil { structured["details"] = data }
            structured.merge(data) { _, new in new }
        }
        error["data"] = structured
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

struct HorizontalDispatchError: Error, @unchecked Sendable {
    enum Code: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        case applicationError = -32000
        case notFound = -32001
        case ambiguous = -32002
        case staleRevision = -32003
        case timeout = -32004
        case recoveryRequired = -32005
        case unsupported = -32006
        case readOnly = -32007
        case authFailed = -32008

        var label: String {
            switch self {
            case .invalidParams, .invalidRequest, .parseError: "INVALID_ARGUMENT"
            case .notFound, .methodNotFound: "NOT_FOUND"
            case .ambiguous: "AMBIGUOUS_SELECTOR"
            case .staleRevision: "STALE_REVISION"
            case .timeout: "TIMEOUT"
            case .recoveryRequired: "RECOVERY_REQUIRED"
            case .unsupported: "UNSUPPORTED_MODEL"
            case .readOnly: "READ_ONLY"
            case .authFailed: "AUTH_FAILED"
            default: "ENGINE_ERROR"
            }
        }
    }

    var code: Code
    var message: String
    var details: JSONDictionary = [:]
    var data: JSONDictionary {
        ["code": code.label, "details": details, "retryable": code == .timeout,
         "outcome": code == .recoveryRequired ? "indeterminate" : [.applicationError, .internalError].contains(code) ? "unknown" : "not_committed"]
    }

    static func unsupported(_ message: String) -> Self { Self(code: .unsupported, message: message) }
    static func ambiguous(_ message: String, candidates: [String]) -> Self {
        Self(code: .ambiguous, message: message, details: ["candidates": candidates.sorted()])
    }

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
