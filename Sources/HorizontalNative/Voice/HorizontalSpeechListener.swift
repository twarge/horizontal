import AVFAudio
import Foundation
import Speech

/// The microphone side of voice control: opens the input, transcribes it on
/// the device with the Speech framework's analyzer, and reports what it hears.
///
/// App-only. The QuickLook extensions compile the workspace but not this
/// file, so nothing shared may name it; the app installs it through
/// `HorizontalVoiceControl.makeEngine` at launch.
///
/// The design's names go to the analyzer as contextual strings, which is the
/// point of hearing in the app rather than through Siri: the transcriber
/// knows "C123" and "GND_ANALOG" are words before it hears them.
@MainActor
final class HorizontalSpeechListener: HorizontalSpeechEngine {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var session: Task<Void, Never>?

    init() {}

    func start(contextualStrings: [String]) -> AsyncStream<HorizontalSpeechEvent> {
        let (stream, events) = AsyncStream<HorizontalSpeechEvent>.makeStream()
        session = Task { [weak self] in
            guard let self else {
                events.finish()
                return
            }
            do {
                try await listen(contextualStrings: contextualStrings, events: events)
            } catch is CancellationError {
            } catch {
                events.yield(.failed(Self.describe(error)))
            }
            events.finish()
        }
        return stream
    }

    func stop() {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        session?.cancel()
        session = nil
    }

    private func listen(contextualStrings: [String], events: AsyncStream<HorizontalSpeechEvent>.Continuation) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw HorizontalSpeechError.microphoneDenied
        }
        let locale = await Self.locale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await Self.ensureModel(for: transcriber, locale: locale) { events.yield(.status($0)) }
        try Task.checkCancellation()

        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw HorizontalSpeechError.noAudioFormat
        }

        // Results are read before analysis starts, so none are missed.
        let results = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                events.yield(result.isFinal ? .final(text) : .volatile(text))
            }
        }
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation
        try startAudio(format: format, into: inputContinuation)
        try await analyzer.start(inputSequence: inputs)
        events.yield(.listening)
        try await results.value
    }

    /// Downloads the model for `locale` if the device does not have it yet.
    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale, status: (String) -> Void) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw HorizontalSpeechError.unsupported(locale)
        case .supported, .downloading:
            status("Downloading the speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            return
        }
    }

    private func startAudio(format: AVAudioFormat, into continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = HorizontalAudioBufferConverter()
        // The tap runs on the audio thread. A closure written here would
        // inherit this class's main-actor isolation and the runtime would
        // assert the moment the audio thread called it; `@Sendable` makes it
        // isolated to nothing, which is what a tap has to be. Everything it
        // touches is its own: the converter, the format, the continuation.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            guard let converted = try? converter.convert(buffer, to: format) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudio() {
        guard audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The transcriber locale nearest the user's: theirs when supported, else
    /// their language, else US English.
    static func locale() async -> Locale {
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return match
        }
        let supported = await SpeechTranscriber.supportedLocales
        if let language = current.language.languageCode?.identifier,
           let match = supported.first(where: { $0.language.languageCode?.identifier == language }) {
            return match
        }
        return supported.first { $0.identifier(.bcp47) == "en-US" } ?? current
    }

    /// Transcribes a recording the way the microphone path does, for tests
    /// that speak through `say` rather than a person. Downloads the model only
    /// when told to; otherwise a missing model is an error, not a wait.
    static func transcribe(fileAt url: URL, contextualStrings: [String] = [], installingModel: Bool = false) async throws -> String {
        let locale = await locale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if installingModel {
            try await ensureModel(for: transcriber, locale: locale) { _ in }
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw HorizontalSpeechError.modelNotInstalled(locale)
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        let collected = Task {
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                pieces.append(String(result.text.characters))
            }
            return pieces.joined(separator: " ")
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HorizontalSpeechError {
            return error.message
        }
        return "Listening stopped: \(error.localizedDescription)"
    }
}

enum HorizontalSpeechError: Error, LocalizedError {
    case microphoneDenied
    case unsupported(Locale)
    case modelNotInstalled(Locale)
    case noAudioFormat

    var message: String {
        switch self {
        case .microphoneDenied:
            "Horizontal needs the microphone to hear you. Allow it in Privacy & Security settings."
        case .unsupported(let locale):
            "Speech in \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) is not supported on this device."
        case .modelNotInstalled(let locale):
            "The speech model for \(locale.identifier) is not installed."
        case .noAudioFormat:
            "The speech analyzer offered no audio format."
        }
    }

    var errorDescription: String? { message }
}

/// Resamples microphone buffers to what the analyzer wants. Used from the
/// audio tap, one buffer at a time, on the audio thread.
final class HorizontalAudioBufferConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format {
            return buffer
        }
        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw HorizontalSpeechError.noAudioFormat
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw HorizontalSpeechError.noAudioFormat
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error {
            throw error
        }
        return converted
    }
}
