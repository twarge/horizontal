import Foundation

/// What the microphone side of voice control reports as it goes.
enum HorizontalSpeechEvent: Sendable {
    /// Something to tell the user while nothing is being heard yet: a model
    /// downloading, say.
    case status(String)
    /// The microphone is open and the transcriber is running.
    case listening
    /// What has been heard so far of the current utterance; will change.
    case volatile(String)
    /// An utterance the transcriber has settled on.
    case final(String)
    /// It stopped, and why.
    case failed(String)
}

/// Hears speech and reports it. The app installs the real one, which owns the
/// microphone; anything else that compiles the workspace (the QuickLook
/// extensions) has none and shows no control.
@MainActor
protocol HorizontalSpeechEngine: AnyObject {
    /// Starts listening. `contextualStrings` are the names the speaker is
    /// likely to say — the design's reference designators and nets — which
    /// bias transcription toward them. The stream ends when listening does.
    func start(contextualStrings: [String]) -> AsyncStream<HorizontalSpeechEvent>
    func stop()
}

/// Voice control for one document: a switch, what is being heard, and what
/// came of it.
///
/// Speech is transcribed on the device by the engine the app installs, each
/// settled utterance is read as a command by `HorizontalVoiceCommandParser`
/// and carried out by `HorizontalVoiceCommandRunner` against the document
/// the workspace registered. The design's names are handed to the transcriber
/// as context, so "C123" comes back as C123 rather than "see one two three";
/// that is the whole reason this lives in the app rather than in Siri, which
/// only hears names an app has published to it, and hears them badly.
@MainActor
final class HorizontalVoiceControl: ObservableObject {
    /// Installed by the app at launch. Nil in the QuickLook extensions.
    static var makeEngine: (() -> any HorizontalSpeechEngine)?

    static var isAvailable: Bool { makeEngine != nil }

    @Published private(set) var isListening = false
    /// What is being heard of the current utterance.
    @Published private(set) var transcript = ""
    /// Something to show while the engine is getting ready.
    @Published private(set) var status: String?
    /// What the last utterance was heard as, and what came of it.
    @Published private(set) var message: String?

    /// The document commands act on. A workspace attaches its own registered
    /// document; the default is whichever is in front.
    var target: () -> HorizontalCommandTarget.Target? = { try? HorizontalCommandTarget.current() }

    /// The controls of the open workspaces, by the handle of their document,
    /// so a request from outside the window — Siri's "start listening" — can
    /// find the one for the document in front.
    private static var controlsByHandle: [Int: WeakControl] = [:]

    private final class WeakControl {
        weak var control: HorizontalVoiceControl?
        init(_ control: HorizontalVoiceControl) { self.control = control }
    }

    static func control(forHandle handle: Int) -> HorizontalVoiceControl? {
        controlsByHandle[handle]?.control
    }

    /// Ties this control to a registered document for as long as it is open.
    func attach(handle: Int) {
        detach()
        target = { HorizontalCommandTarget.target(handle: handle) }
        attachedHandle = handle
        Self.controlsByHandle[handle] = WeakControl(self)
    }

    /// Stops listening and forgets the document; called when it closes.
    func detach() {
        stop()
        if let attachedHandle {
            Self.controlsByHandle[attachedHandle] = nil
        }
        attachedHandle = nil
    }

    private var attachedHandle: Int?

    private var engine: (any HorizontalSpeechEngine)?
    private var session: Task<Void, Never>?
    private var messageTimer: Task<Void, Never>?
    /// A settled utterance that was no command on its own — "highlight",
    /// with the name still to come — kept to prepend to the next one.
    private var pending = ""
    private var pendingSince: ContinuousClock.Instant?
    /// What the last command named and what it did, so "zoom" after
    /// "highlight C50" means C50, and "R12" after it means highlight R12.
    private var previousSubject: [HorizontalDesignObject] = []
    private var previousVerb: HorizontalVoiceVerb?

    func toggle() {
        if isListening {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isListening, let make = Self.makeEngine else { return }
        guard let target = target() else {
            show("No project is open.")
            return
        }
        let engine = make()
        self.engine = engine
        isListening = true
        transcript = ""
        message = nil
        status = "Getting ready…"
        pending = ""
        previousSubject = []
        previousVerb = nil
        let stream = engine.start(contextualStrings: Self.contextualStrings(for: target))
        session = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
            self?.finish()
        }
    }

    func stop() {
        guard isListening else { return }
        engine?.stop()
        session?.cancel()
        finish()
    }

    private func finish() {
        session = nil
        engine = nil
        isListening = false
        transcript = ""
        status = nil
    }

    private func handle(_ event: HorizontalSpeechEvent) {
        switch event {
        case .status(let text):
            status = text
        case .listening:
            status = nil
        case .volatile(let text):
            transcript = text
        case .final(let text):
            transcript = ""
            run(text)
        case .failed(let text):
            show(text)
            stop()
        }
    }

    /// Reads one settled utterance as a command and carries it out.
    func run(_ text: String) {
        guard let target = target() else {
            show("No project is open.")
            return
        }
        if let pendingSince, ContinuousClock.now - pendingSince > .seconds(4) {
            pending = ""
        }
        let heard = [pending, text].filter { !$0.isEmpty }.joined(separator: " ")
        let vocabulary = HorizontalVoiceVocabulary(
            objects: HorizontalCommandTarget.nameableObjects(in: target),
            sheetNames: HorizontalCommandTarget.sheets(in: target).map(\.name),
            previousSubject: previousSubject,
            previousVerb: previousVerb
        )
        var command = HorizontalVoiceCommandParser.parse(heard, vocabulary: vocabulary)
        var said = heard
        if !pending.isEmpty, !Self.isAnswer(command) {
            // The fragment did not lead into this; on its own it may be whole.
            let alone = HorizontalVoiceCommandParser.parse(text, vocabulary: vocabulary)
            if Self.isAnswer(alone) {
                command = alone
                said = text
            }
        }
        if case .unrecognized = command, pending.isEmpty,
           text.split(separator: " ").count <= 2 || HorizontalVoiceCommandParser.beginsWithVerb(text) {
            // Too short to be sure it is not the first half of a command, or
            // a verb with the name still to come: "highlight what".
            pending = text
            pendingSince = .now
            return
        }
        pending = ""
        pendingSince = nil
        remember(command)
        show("“\(said)” — \(HorizontalVoiceCommandRunner.run(command, in: target))")
    }

    /// Whether `command` is one to carry out, as against a reading that found
    /// no command or no thing.
    private static func isAnswer(_ command: HorizontalVoiceCommand) -> Bool {
        switch command {
        case .unrecognized, .nothingNamed, .noSubject: false
        default: true
        }
    }

    /// Keeps what a command named, and the verb, for the sentences after it.
    private func remember(_ command: HorizontalVoiceCommand) {
        switch command {
        case .highlight(let objects):
            previousSubject = objects
            previousVerb = .highlight
        case .select(let objects):
            previousSubject = objects
            previousVerb = .select
        case .zoom(let objects, _):
            previousSubject = objects
            previousVerb = .zoom
        case .among(let verb, let parts):
            if let target = target() {
                let nets = HorizontalCommandTarget.netsAmong(parts, in: target)
                if !nets.isEmpty {
                    previousSubject = nets
                    previousVerb = verb
                }
            }
        default:
            break
        }
    }

    private func show(_ text: String) {
        message = text
        messageTimer?.cancel()
        messageTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    /// What the speaker is likely to say: every name in the design, the sheet
    /// names, the kinds, the layer views, and the verbs.
    static func contextualStrings(for target: HorizontalCommandTarget.Target) -> [String] {
        let names = HorizontalCommandTarget.nameableObjects(in: target).map(\.name)
        let sheets = HorizontalCommandTarget.sheets(in: target).map(\.name)
        let kinds = HorizontalObjectFamily.allCases.map(\.spokenTitle)
        let verbs = ["highlight", "select", "zoom to", "go to", "show the board", "show the schematic", "show 3D",
                     "hide", "clear highlight", "sheet", "next sheet", "previous sheet", "undo", "redo",
                     "top layer", "bottom layer", "silkscreen", "routing", "all layers", "copper only",
                     "zoom in", "zoom out", "flip the board", "show the bottom", "show the top"]
        return Array(Set(names + sheets + kinds + verbs)).sorted()
    }
}
