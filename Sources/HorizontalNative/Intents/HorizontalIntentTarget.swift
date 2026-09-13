import Foundation
#if os(macOS)
import AppKit
#endif

/// Which open document an App Intent acts on, and the verbs it acts with.
///
/// The intents do not reimplement anything: they call the same dispatch
/// methods the automation channel exposes, against the handle the workspace
/// registered when it opened the document. So "highlight R18" from Siri and
/// `highlight` from an agent are one code path, and stay that way.
///
/// On the Mac the document in front is whatever the document controller says
/// it is. The iPad has no document controller, so its workspace tells the
/// dispatch session which document's scene most recently came to the front,
/// and that is what an intent acts on there.
@MainActor
enum HorizontalIntentTarget {
    struct Target {
        var handle: Int
        var document: HorizontalLiveDocument
    }

    /// The document in front, or the only one open.
    ///
    /// With one document open the answer is the same however it is asked;
    /// with none there is nothing an intent can do that is not a lie.
    static func current() throws -> Target {
        let (live, front) = HorizontalDispatchSession.shared.perform { session in
            (session.openEntries.compactMap { entry in entry.live.map { Target(handle: entry.handle, document: $0) } },
             session.frontLiveDocumentHandle)
        }
        guard !live.isEmpty else {
            throw HorizontalIntentError.noProjectOpen
        }
        guard live.count > 1 else {
            return live[0]
        }
        #if os(macOS)
        // `currentDocument` is what the user would call "the project I am
        // looking at".
        if let frontURL = NSDocumentController.shared.currentDocument?.fileURL?.standardizedFileURL,
           let match = live.first(where: { $0.document.url.standardizedFileURL == frontURL }) {
            return match
        }
        #endif
        if let front, let match = live.first(where: { $0.handle == front }) {
            return match
        }
        return live[0]
    }

    /// `current()`, but willing to wait for a document the app is still
    /// bringing back. An intent that opens the app runs while its windows are
    /// being restored, and a document is not registered until its view has
    /// appeared and loaded — on the iPad in particular, Siri launching the
    /// app cold would otherwise be told nothing is open. Gives up after
    /// `timeout` with the same error `current()` throws.
    static func current(waitingUpTo timeout: Duration) async throws -> Target {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            do {
                return try current()
            } catch {
                guard clock.now < deadline else {
                    throw error
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Calls a dispatch method against `handle` and returns its result, or
    /// throws what it refused with — those messages are written for whoever
    /// has to fix the request, which here is the person who asked.
    @discardableResult
    static func call(_ method: String, handle: Int, params: JSONDictionary = [:]) throws -> JSONDictionary {
        // The live channel does this before every request. An intent is a
        // request from the same place, and a component placed a moment ago
        // has to be nameable now, not after the next channel request.
        HorizontalDispatchSession.shared.syncLiveEntries()
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
