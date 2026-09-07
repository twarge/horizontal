import Foundation
import HorizontalNative

// The C ABI the Python package loads with ctypes. One call carries a JSON-RPC
// request and returns a JSON-RPC response; the caller frees the response.

@_cdecl("horizontal_call")
public func horizontal_call(_ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let request else {
        return strdup(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Null request."}}"#)
    }
    return strdup(HorizontalDispatch.call(String(cString: request)))
}

@_cdecl("horizontal_free")
public func horizontal_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

@_cdecl("horizontal_api_version")
public func horizontal_api_version() -> Int32 {
    Int32(HorizontalDispatch.apiVersion)
}
