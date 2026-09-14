import Foundation

/// Carries out a spoken command against a document and says what happened,
/// in one sentence written for the person who spoke.
@MainActor
enum HorizontalVoiceCommandRunner {
    static func run(_ command: HorizontalVoiceCommand, in target: HorizontalCommandTarget.Target) -> String {
        do {
            return try perform(command, in: target)
        } catch let error as HorizontalCommandError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    private static func perform(_ command: HorizontalVoiceCommand, in target: HorizontalCommandTarget.Target) throws -> String {
        switch command {
        case .highlight(let objects):
            try HorizontalCommandTarget.highlight(objects, in: target)
            return "Highlighted \(list(objects))."
        case .select(let objects):
            try HorizontalCommandTarget.select(objects, in: target)
            return "Selected \(list(objects))."
        case .clearHighlight:
            try HorizontalCommandTarget.clearHighlight(in: target)
            return "Highlight cleared."
        case .clearSelection:
            try HorizontalCommandTarget.clearSelection(in: target)
            return "Selection cleared."
        case .zoom(let object, let pane):
            let framed = try HorizontalCommandTarget.frame(object, pane: pane, in: target)
            return framed.isEmpty ? "Zoomed to \(object.name)." : "Zoomed to \(object.name) in \(list(Set(framed)))."
        case .showPanes(let panes):
            try HorizontalCommandTarget.showPanes(panes, in: target)
            return "Showing \(list(panes))."
        case .hidePanes(let panes):
            let showing = HorizontalCommandTarget.visiblePanes(in: target)
            let remaining = showing.subtracting(panes)
            guard remaining != showing else {
                return "\(list(panes).capitalizedFirst) \(panes.count == 1 ? "is" : "are") not showing."
            }
            guard !remaining.isEmpty else {
                throw HorizontalCommandError.refused("That would hide every pane. Say which one to show instead.")
            }
            try HorizontalCommandTarget.showPanes(remaining, in: target)
            return "Hid \(list(panes.intersection(showing)))."
        case .showLayers(let preset):
            try HorizontalCommandTarget.showLayers(preset, in: target)
            return preset == .flipView ? "Turned the board over." : "Showing \(preset.spokenTitle)."
        case .zoomBy(let factor, let pane):
            try HorizontalCommandTarget.zoom(by: factor, pane: pane, in: target)
            if factor <= 0 {
                return pane.map { "Fit \(list([$0]))." } ?? "Fit the view."
            }
            return factor > 1 ? "Zoomed in." : "Zoomed out."
        case .between(let verb, let a, let b):
            let nets = HorizontalCommandTarget.netsBetween(a, b, in: target)
            guard !nets.isEmpty else {
                return "Nothing connects \(a.name) and \(b.name)."
            }
            switch verb {
            case .highlight:
                try HorizontalCommandTarget.highlight(nets, in: target)
                return "Highlighted \(list(nets)) between \(a.name) and \(b.name)."
            case .select:
                try HorizontalCommandTarget.select(nets, in: target)
                return "Selected \(list(nets))."
            case .zoom:
                guard nets.count == 1 else {
                    return "\(a.name) and \(b.name) share \(list(nets)). Zoom to which one?"
                }
                let framed = try HorizontalCommandTarget.frame(nets[0], pane: nil, in: target)
                return framed.isEmpty ? "Zoomed to \(nets[0].name)." : "Zoomed to \(nets[0].name) in \(list(Set(framed)))."
            }
        case .noSubject(let verb):
            let what = verb == .zoom ? "zoom to" : (verb == .select ? "select" : "highlight")
            return "Nothing to \(what) yet. Name something first."
        case .severalToFrame(let objects):
            return "That is \(list(objects)). Zoom to which one?"
        case .showSheet(let request):
            let sheet = try HorizontalCommandTarget.showSheet(request, in: target)
            return sheet.name.isEmpty ? "Sheet \(sheet.index)." : "Sheet \(sheet.index), \(sheet.name)."
        case .undo:
            return "Undid \(try HorizontalCommandTarget.undo(redo: false, in: target))."
        case .redo:
            return "Redid \(try HorizontalCommandTarget.undo(redo: true, in: target))."
        case .nothingNamed(let said, let family):
            if let family {
                return "There is no \(family.spokenTitle) \(said) in \(target.document.title)."
            }
            return "Nothing in \(target.document.title) is called \(said)."
        case .ambiguous(let found, let said):
            let names = found.prefix(4).map(\.name).joined(separator: ", ")
            let more = found.count > 4 ? " and \(found.count - 4) more" : ""
            return "\(said.capitalizedFirst) could be \(names)\(more). Say the kind, or the whole name."
        case .unrecognized:
            return "Not a command I know. Try “highlight C12”, “zoom to ground”, “show the board” or “sheet 2”."
        }
    }

    /// "C12", "C12 and GND", "C1, C2 and C3", or "76 components" when there are
    /// too many to read out.
    static func list(_ objects: [HorizontalDesignObject]) -> String {
        if objects.count > 4 {
            let components = objects.filter { $0.kind == .component }.count
            let nets = objects.count - components
            return [components > 0 ? "\(components) component\(components == 1 ? "" : "s")" : nil,
                    nets > 0 ? "\(nets) net\(nets == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " and ")
        }
        return joined(objects.map(\.name))
    }

    /// "the schematic and the board", in pane order.
    static func list(_ panes: Set<HorizontalPane>) -> String {
        joined(HorizontalPane.allCases.filter { panes.contains($0) }.map { "the \($0.title.lowercased())" })
    }

    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: "nothing"
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
