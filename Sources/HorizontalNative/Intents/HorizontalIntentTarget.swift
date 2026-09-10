#if os(macOS)
import AppKit
import Foundation

/// Which open document an App Intent acts on, and the verbs it acts with.
///
/// The intents do not reimplement anything: they call the same dispatch
/// methods the automation channel exposes, against the handle the workspace
/// registered when it opened the document. So "highlight R18" from Siri and
/// `highlight` from an agent are one code path, and stay that way.
///
/// macOS only, because registering a document as live is macOS only — the
/// iPad workspace has no live channel to reach.
@MainActor
enum HorizontalIntentTarget {
    struct Target {
        var handle: Int
        var document: HorizontalLiveDocument
    }

    /// The document in front, or the only one open.
    ///
    /// `currentDocument` is what the user would call "the project I am looking
    /// at"; with one document open the answer is the same either way, and with
    /// none there is nothing an intent can do that is not a lie.
    static func current() throws -> Target {
        let live = HorizontalDispatchSession.shared
            .perform { $0.openEntries }
            .compactMap { entry in entry.live.map { Target(handle: entry.handle, document: $0) } }
        guard !live.isEmpty else {
            throw HorizontalIntentError.noProjectOpen
        }
        if live.count > 1,
           let front = NSDocumentController.shared.currentDocument?.fileURL?.standardizedFileURL,
           let match = live.first(where: { $0.document.url.standardizedFileURL == front }) {
            return match
        }
        return live[0]
    }

    /// Calls a dispatch method against `handle` and returns its result, or
    /// throws what it refused with — those messages are written for whoever
    /// has to fix the request, which here is the person who asked.
    @discardableResult
    static func call(_ method: String, handle: Int, params: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = params
        params["handle"] = handle
        let response = HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params] as JSONDictionary
        )
        if let error = response["error"] as? JSONDictionary {
            throw HorizontalIntentError.refused(error.string("message") ?? "Horizontal could not do that.")
        }
        return response["result"] as? JSONDictionary ?? [:]
    }

    /// Everything an intent can name: the components and nets of the document
    /// in front. Empty when nothing is open, rather than an error — a query
    /// runs whenever Siri or Shortcuts feels like it, including with the app
    /// shut, and an error there is noise.
    static func nameableObjects() -> [HorizontalDesignObjectEntity] {
        guard let target = try? current() else {
            return []
        }
        let index = HorizontalDesignIndex(project: target.document.currentProject())
        let components = index.sortedComponents.map {
            HorizontalDesignObjectEntity(kind: .component, name: $0.refdes, detail: $0.value)
        }
        let nets = index.sortedNets.filter { !$0.name.isEmpty }.map {
            HorizontalDesignObjectEntity(kind: .net, name: $0.name, detail: $0.netClassName ?? "")
        }
        return components + nets
    }
}

enum HorizontalIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noProjectOpen
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noProjectOpen:
            "Horizontal has no project open."
        case .refused(let message):
            "\(message)"
        }
    }
}
#endif
