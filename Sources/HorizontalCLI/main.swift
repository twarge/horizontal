import Foundation
import HorizontalNative

// `horizontal`: the dispatch layer on the command line.
//
//   horizontal call <method> ['{"param": value}']   one request, pretty-printed
//   horizontal serve                                 newline-delimited JSON-RPC on stdin/stdout
//   horizontal methods                               list the methods

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let text = """
    usage: horizontal call <method> ['{"param": value, ...}']
           horizontal serve
           horizontal methods

    Every request is JSON-RPC 2.0; `serve` reads one request per line on stdin
    and writes one response per line on stdout, for the Python package's
    isolated mode and for scripts in any language.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(64)
}

func prettyPrinted(_ responseJSON: String) -> String {
    guard let data = responseJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: pretty, encoding: .utf8) else {
        return responseJSON
    }
    return text
}

func request(method: String, paramsJSON: String) -> String {
    let params = paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    let escapedMethod = method.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"jsonrpc":"2.0","id":1,"method":"\#(escapedMethod)","params":\#(params.isEmpty ? "{}" : params)}"#
}

switch arguments.first {
case "serve":
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            continue
        }
        print(HorizontalDispatch.call(trimmed))
        fflush(stdout)
    }
case "call":
    guard arguments.count >= 2 else {
        usage()
    }
    let response = HorizontalDispatch.call(request(method: arguments[1], paramsJSON: arguments.count > 2 ? arguments[2] : "{}"))
    print(prettyPrinted(response))
case "methods":
    print(prettyPrinted(HorizontalDispatch.call(request(method: "methods", paramsJSON: "{}"))))
default:
    usage()
}
