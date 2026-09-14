import Foundation
#if os(macOS)
import AppKit
#endif

/// Which open document a request acts on — spoken in the app, or asked of
/// Siri — and the verbs it acts with.
///
/// Nothing here reimplements anything: the verbs are the dispatch methods the
/// automation channel exposes, called against the handle the workspace
/// registered when it opened the document. So "highlight R18" said aloud and
/// `highlight` from an agent are one code path, and stay that way.
///
/// A workspace that knows its own handle asks for that. Otherwise, on the Mac
/// the document in front is whatever the document controller says it is; the
/// iPad has no document controller, so its workspace tells the dispatch
/// session which document's scene most recently came to the front.
@MainActor
enum HorizontalCommandTarget {
    struct Target {
        var handle: Int
        var document: HorizontalLiveDocument
    }

    /// The document registered under `handle`, if it still is.
    static func target(handle: Int) -> Target? {
        HorizontalDispatchSession.shared.perform { session in
            session.openEntries.first { $0.handle == handle }?.live.map { Target(handle: handle, document: $0) }
        }
    }

    /// The document in front, or the only one open.
    ///
    /// With one document open the answer is the same however it is asked;
    /// with none there is nothing a request can do that is not a lie.
    static func current() throws -> Target {
        let (live, front) = HorizontalDispatchSession.shared.perform { session in
            (session.openEntries.compactMap { entry in entry.live.map { Target(handle: entry.handle, document: $0) } },
             session.frontLiveDocumentHandle)
        }
        guard !live.isEmpty else {
            throw HorizontalCommandError.noProjectOpen
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
        // The live channel does this before every request. A spoken request
        // comes from the same place, and a component placed a moment ago has
        // to be nameable now, not after the next channel request.
        HorizontalDispatchSession.shared.syncLiveEntries()
        var params = params
        params["handle"] = handle
        let response = HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params] as JSONDictionary
        )
        if let error = response["error"] as? JSONDictionary {
            throw HorizontalCommandError.refused(error.string("message") ?? "Horizontal could not do that.")
        }
        return response["result"] as? JSONDictionary ?? [:]
    }

    /// Everything a request can name in `target`: its components and nets.
    static func nameableObjects(in target: Target) -> [HorizontalDesignObject] {
        let index = HorizontalDesignIndex(project: target.document.currentProject())
        let components = index.sortedComponents.map {
            HorizontalDesignObject(kind: .component, name: $0.refdes, detail: $0.value)
        }
        let nets = index.sortedNets.filter { !$0.name.isEmpty }.map {
            HorizontalDesignObject(kind: .net, name: $0.name, detail: $0.netClassName ?? "")
        }
        return components + nets
    }

    /// The nets with a pin on both `a` and `b` — what "the nets between C48
    /// and C50" means. Either may itself be a net, in which case it is the
    /// answer when the other is on it.
    static func netsBetween(_ a: HorizontalDesignObject, _ b: HorizontalDesignObject, in target: Target) -> [HorizontalDesignObject] {
        let index = HorizontalDesignIndex(project: target.document.currentProject())
        func netIDs(of object: HorizontalDesignObject) -> Set<String>? {
            switch object.kind {
            case .component:
                return index.component(refdes: object.name).map { Set($0.pins.compactMap(\.netID)) }
            case .net:
                return index.sortedNets.first { $0.name == object.name }.map { [$0.id] }
            }
        }
        guard let first = netIDs(of: a), let second = netIDs(of: b) else { return [] }
        return index.sortedNets
            .filter { first.contains($0.id) && second.contains($0.id) && !$0.name.isEmpty }
            .map { HorizontalDesignObject(kind: .net, name: $0.name, detail: $0.netClassName ?? "") }
    }

    /// The schematic sheets of `target`, in page order.
    static func sheets(in target: Target) -> [HorizontalDesignSheet] {
        HorizontalDesignIndex(project: target.document.currentProject()).sheets
    }

    // MARK: - Verbs

    private static func names(_ objects: [HorizontalDesignObject], _ kind: HorizontalDesignObject.Kind) -> [String] {
        objects.filter { $0.kind == kind }.map(\.name)
    }

    /// Highlights these and nothing else.
    static func highlight(_ objects: [HorizontalDesignObject], in target: Target) throws {
        try call("highlight", handle: target.handle,
                 params: ["components": names(objects, .component), "nets": names(objects, .net)])
    }

    static func clearHighlight(in target: Target) throws {
        try highlight([], in: target)
    }

    /// Selects these and nothing else.
    static func select(_ objects: [HorizontalDesignObject], in target: Target) throws {
        try call("select", handle: target.handle,
                 params: ["components": names(objects, .component), "nets": names(objects, .net)])
    }

    static func clearSelection(in target: Target) throws {
        try select([], in: target)
    }

    /// Frames one object and returns the panes it was framed in. With no pane
    /// asked for, that is every pane that is showing and can show it — the
    /// 3D view included — because "zoom to C50" with three views open means
    /// all three.
    static func frame(_ object: HorizontalDesignObject, pane: HorizontalPane?, in target: Target) throws -> [HorizontalPane] {
        var params: JSONDictionary = object.kind == .component ? ["refdes": object.name] : ["net": object.name]
        params["pane"] = pane?.rawValue ?? "all"
        let result = try call("zoom_to", handle: target.handle, params: params)
        let names = (result["panes"] as? [String]) ?? [result.string("pane")].compactMap { $0 }
        return names.compactMap { HorizontalPane(rawValue: $0) }
    }

    /// Shows a board layer view, revealing the board pane.
    static func showLayers(_ preset: HorizontalBoardLayerPreset, in target: Target) throws {
        try call("show_layers", handle: target.handle, params: ["preset": preset.rawValue])
    }

    /// Zooms a pane's view — the one the user is working in, when unsaid. A
    /// factor of 0 fits the whole view.
    static func zoom(by factor: Double, pane: HorizontalPane?, in target: Target) throws {
        var params: JSONDictionary = ["factor": factor]
        if let pane {
            params["pane"] = pane.rawValue
        }
        try call("zoom", handle: target.handle, params: params)
    }

    /// Shows exactly these panes.
    static func showPanes(_ panes: Set<HorizontalPane>, in target: Target) throws {
        try call("show_panes", handle: target.handle,
                 params: ["panes": HorizontalPane.allCases.filter { panes.contains($0) }.map(\.rawValue)])
    }

    /// The panes `target` is showing now.
    static func visiblePanes(in target: Target) -> Set<HorizontalPane> {
        Set(target.document.selection().panes.compactMap { HorizontalPane(rawValue: $0) })
    }

    /// Shows the sheet a request means, and says which. Reads the request
    /// against the sheets that exist rather than handing it to the channel
    /// as said, because "the ADC sheet" is what people say and `show_sheet`
    /// takes an exact name.
    static func showSheet(_ request: HorizontalSheetRequest, in target: Target) throws -> HorizontalDesignSheet {
        let sheets = sheets(in: target)
        let title = target.document.title
        guard !sheets.isEmpty else {
            throw HorizontalCommandError.refused("\(title) has no schematic sheets.")
        }
        let sheet: HorizontalDesignSheet?
        switch request {
        case .number(let number):
            sheet = sheets.first { $0.index == number }
        case .first:
            sheet = sheets.first
        case .last:
            sheet = sheets.last
        case .next, .previous:
            let currentID = target.document.currentSheet()
            let position = sheets.firstIndex { $0.id == currentID } ?? (request == .next ? -1 : sheets.count)
            let wanted = request == .next ? position + 1 : position - 1
            guard sheets.indices.contains(wanted) else {
                throw HorizontalCommandError.refused(request == .next ? "This is the last sheet." : "This is the first sheet.")
            }
            sheet = sheets[wanted]
        case .named(let name):
            let wanted = HorizontalSpokenMatcher.spoken(name)
            let exact = sheets.filter { HorizontalSpokenMatcher.spoken($0.name) == wanted }
            let found = exact.isEmpty ? sheets.filter { HorizontalSpokenMatcher.spoken($0.name).contains(wanted) } : exact
            guard found.count <= 1 else {
                let names = found.map(\.name).joined(separator: ", ")
                throw HorizontalCommandError.refused("\(name) could be \(names). Say the whole name, or the number.")
            }
            sheet = found.first
        }
        guard let sheet else {
            throw HorizontalCommandError.refused("There is no sheet \(request.spoken) in \(title).")
        }
        var params: JSONDictionary = ["sheet_id": sheet.id]
        if let blockID = sheet.blockID {
            params["block_id"] = blockID
        }
        try call("show_sheet", handle: target.handle, params: params)
        return sheet
    }

    /// Takes back the last step, or puts one back; returns what it was.
    static func undo(redo: Bool, in target: Target) throws -> String {
        let result = try call("undo", handle: target.handle, params: redo ? ["redo": true] : [:])
        return result.string(redo ? "redone" : "undone") ?? "the last edit"
    }
}

/// What a request could not do, said for the person who asked. Foundation's
/// `CustomLocalizedStringResourceConvertible` is what lets an App Intent throw
/// one of these and have Siri read the message.
enum HorizontalCommandError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noProjectOpen
    case refused(String)

    var message: String {
        switch self {
        case .noProjectOpen: "Horizontal has no project open."
        case .refused(let message): message
        }
    }

    var errorDescription: String? { message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
