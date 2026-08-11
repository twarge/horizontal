import AppKit
#if canImport(HorizontalNative)
import HorizontalNative
#endif
import os
import PDFKit
@preconcurrency import QuickLookUI

final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private let logger = Logger(subsystem: "com.twarge.horizontal", category: "QuickLookPreview")
    private let pdfView = PDFView()
    private let progress = NSProgressIndicator()
    private let errorLabel = NSTextField(labelWithString: "")
    private var generatedPDFURL: URL?

    override func loadView() {
        preferredContentSize = CGSize(width: 960, height: 720)
        let rootView = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = rootView

        configurePDFView()
        configureProgressIndicator()
        configureErrorLabel()
        showLoading()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let size = preferredContentSize
        let startedAt = Date()
        nonisolated(unsafe) let completion = handler
        logger.notice("Preparing preview for \(url.path, privacy: .public), size \(size.width, privacy: .public)x\(size.height, privacy: .public)")

        showLoading()
        Task { @MainActor in
            do {
                let pdfURL = try await Task.detached(priority: .userInitiated) {
                    try HorizontalSchematicPreviewRenderer.pdfURL(forProjectAt: url)
                }.value
                try displayPDF(at: pdfURL)
                logger.notice("Preview ready for \(url.path, privacy: .public) in \(Date().timeIntervalSince(startedAt), privacy: .public)s")
                completion(nil)
            } catch {
                logger.error("Preview failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                displayError(error)
                completion(nil)
            }
        }
    }

    private func displayPDF(at url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw NSError(
                domain: "com.twarge.horizontal.QuickLook",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open generated schematic preview."]
            )
        }
        generatedPDFURL = url
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.goToFirstPage(nil)
        pdfView.isHidden = false
        progress.isHidden = true
        progress.stopAnimation(nil)
        errorLabel.isHidden = true
    }

    private func displayError(_ error: Error) {
        pdfView.document = nil
        pdfView.isHidden = true
        progress.isHidden = true
        progress.stopAnimation(nil)
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
    }

    private func showLoading() {
        pdfView.isHidden = true
        errorLabel.isHidden = true
        progress.isHidden = false
        progress.startAnimation(nil)
    }

    private func configurePDFView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureProgressIndicator() {
        progress.style = .spinning
        progress.controlSize = .large
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureErrorLabel() {
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 4
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28)
        ])
    }
}
