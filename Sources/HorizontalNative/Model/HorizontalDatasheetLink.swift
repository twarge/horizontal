import Foundation

/// A part's datasheet as a link reads it: its site and an ellipsis,
/// "murata.com/…", so it fits on one line beside its label. The whole
/// address is what the link opens and what its tooltip shows.
enum HorizontalDatasheetLink {
    /// The address a datasheet field names: a URL, or a bare address such
    /// as "www.ti.com/lit/ds/symlink/opa328.pdf", taken as https. Nil for
    /// text that names none.
    static func url(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return nil
    }

    /// The site without "www.", then "/…" when the address goes further
    /// than the site's front page. An address with no site (a file) reads
    /// as its file name.
    static func shortText(_ url: URL) -> String {
        guard var host = url.host(percentEncoded: false), !host.isEmpty else {
            return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        let path = url.path(percentEncoded: false)
        let goesFurther = (!path.isEmpty && path != "/") || url.query(percentEncoded: false) != nil
        return goesFurther ? host + "/…" : host
    }
}
