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

/// Where responses go: what standard output was when the tool started.
///
/// A response is the only thing a caller may read there — `serve` promises one
/// line for each request — and the libraries under the dispatch layer do not
/// all know that: OpenCascade prints transfer statistics when it writes a STEP
/// file. So standard output is kept for responses under a descriptor of its
/// own, and descriptor 1 is pointed at standard error, where anything a
/// library prints is a diagnostic and no part of the answer.
let responses: FileHandle = {
    let kept = dup(STDOUT_FILENO)
    guard kept >= 0 else { return .standardOutput }
    fflush(stdout)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    return FileHandle(fileDescriptor: kept, closeOnDealloc: true)
}()

func respond(_ text: String) {
    do {
        try responses.write(contentsOf: Data((text + "\n").utf8))
    } catch {
        // The reader has gone; there is nobody left to answer.
        exit(74)
    }
}

switch arguments.first {
case "serve":
    _ = responses
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            continue
        }
        respond(HorizontalDispatch.call(trimmed))
    }
case "call":
    guard arguments.count >= 2 else {
        usage()
    }
    _ = responses
    let response = HorizontalDispatch.call(request(method: arguments[1], paramsJSON: arguments.count > 2 ? arguments[2] : "{}"))
    respond(prettyPrinted(response))
case "methods":
    respond(prettyPrinted(HorizontalDispatch.call(request(method: "methods", paramsJSON: "{}"))))
default:
    usage()
}
