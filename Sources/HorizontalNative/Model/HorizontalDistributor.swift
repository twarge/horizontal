import Foundation

/// One part as a distributor is asked about it: its MPN, and its
/// manufacturer to choose between products that share the MPN.
struct HorizontalPartQuery: Hashable, Sendable {
    var mpn: String
    var manufacturer: String

    init(mpn: String, manufacturer: String) {
        self.mpn = mpn.trimmingCharacters(in: .whitespacesAndNewlines)
        self.manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(part: HorizontalPoolPart) {
        self.init(mpn: part.mpn, manufacturer: part.manufacturer)
    }

    /// A part in the Pools pane, by its MPN (its base's, for a derived part
    /// that inherits it). Any other kind of item has none.
    init(item: HorizontalPoolLibraryItem) {
        self.init(mpn: item.category == .part ? item.mpn : "", manufacturer: item.manufacturer)
    }

    var key: String {
        Self.normalizedMPN(mpn) + "\u{1F}" + Self.normalizedManufacturer(manufacturer)
    }

    static func normalizedMPN(_ mpn: String) -> String {
        mpn.uppercased().filter { !$0.isWhitespace }
    }

    static func normalizedManufacturer(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// One name inside the other once case, spaces and punctuation are
    /// gone: Murata and Murata Electronics, Maxim Integrated and DigiKey's
    /// Analog Devices Inc./Maxim Integrated. Names shorter than three
    /// letters (TI, ST) match nothing; the MPN chooses for them.
    static func manufacturersMatch(_ a: String, _ b: String) -> Bool {
        let x = normalizedManufacturer(a)
        let y = normalizedManufacturer(b)
        guard x.count >= 3, y.count >= 3 else { return false }
        return x.contains(y) || y.contains(x)
    }
}

/// A distributor whose page for a part the part's context menu opens — on
/// the schematic, on the board, and in the Parts and Pools panes — while
/// Settings has it turned on: DigiKey and Mouser.
enum HorizontalDistributor: String, CaseIterable, Identifiable, Sendable {
    case digiKey
    case mouser

    var id: String { rawValue }

    var name: String {
        switch self {
        case .digiKey: "DigiKey"
        case .mouser: "Mouser"
        }
    }

    /// The distributor's search for an MPN. DigiKey's goes straight to the
    /// product's page when it has exactly that part.
    func searchURL(mpn: String) -> URL? {
        switch self {
        case .digiKey:
            Self.url("https://www.digikey.com/en/products/result", query: ["keywords": mpn])
        case .mouser:
            Self.url("https://www.mouser.com/c/", query: ["q": mpn])
        }
    }

    /// An address whose query carries each value as itself: URLComponents
    /// leaves a `+` alone, which a search reads as a space, so `+`, `&`, `=`
    /// and `#` are encoded too.
    private static func url(_ base: String, query: KeyValuePairs<String, String>) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        guard var components = URLComponents(string: base) else { return nil }
        components.percentEncodedQuery = query.map { item in
            "\(item.key)=\(item.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.value)"
        }.joined(separator: "&")
        return components.url
    }
}

/// A part's Open on <distributor> menu item.
struct HorizontalPartPageLink: Identifiable, Equatable, Sendable {
    var distributor: HorizontalDistributor
    var url: URL

    var id: HorizontalDistributor { distributor }
    var title: String { "Open on \(distributor.name)" }

    /// One link per distributor turned on, for a part with an MPN: the
    /// product page the distributor's API answered with, which follows the
    /// part's manufacturer, when it has answered (Mouser's only while its
    /// answer is held, which is never long); otherwise the distributor's
    /// search for the MPN, so a link needs no credentials and no wait.
    @MainActor
    static func links(
        mpn: String,
        manufacturer: String,
        digiKey: HorizontalDigiKeyStockMonitor = .shared,
        mouser: HorizontalMouserStockMonitor = .shared
    ) -> [HorizontalPartPageLink] {
        let query = HorizontalPartQuery(mpn: mpn, manufacturer: manufacturer)
        guard !query.mpn.isEmpty else { return [] }
        return HorizontalDistributor.allCases.compactMap { distributor in
            let url: URL?
            switch distributor {
            case .digiKey:
                guard digiKey.isEnabled else { return nil }
                url = digiKey.productURL(for: query) ?? distributor.searchURL(mpn: query.mpn)
            case .mouser:
                guard mouser.isEnabled else { return nil }
                url = mouser.productURL(for: query) ?? distributor.searchURL(mpn: query.mpn)
            }
            return url.map { HorizontalPartPageLink(distributor: distributor, url: $0) }
        }
    }
}
