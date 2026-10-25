import Foundation

/// A distributor whose page for a part the part's context menu opens — on
/// the schematic, on the board, and in the Parts and Pools panes — while
/// Settings has it turned on. DigiKey is the only one so far.
enum HorizontalDistributor: String, CaseIterable, Identifiable, Sendable {
    case digiKey

    var id: String { rawValue }

    var name: String {
        switch self {
        case .digiKey: "DigiKey"
        }
    }

    /// The distributor's search for an MPN. DigiKey's goes straight to the
    /// product's page when it has exactly that part.
    func searchURL(mpn: String) -> URL? {
        switch self {
        case .digiKey:
            Self.url("https://www.digikey.com/en/products/result", query: ["keywords": mpn])
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
    /// product page DigiKey's API answered with, which follows the part's
    /// manufacturer, when it has answered; otherwise the distributor's search
    /// for the MPN, so a link needs no credentials and no wait.
    @MainActor
    static func links(
        mpn: String,
        manufacturer: String,
        digiKey: HorizontalDigiKeyStockMonitor = .shared
    ) -> [HorizontalPartPageLink] {
        let query = HorizontalDigiKeyQuery(mpn: mpn, manufacturer: manufacturer)
        guard !query.mpn.isEmpty else { return [] }
        return HorizontalDistributor.allCases.compactMap { distributor in
            let url: URL?
            switch distributor {
            case .digiKey:
                guard digiKey.isEnabled else { return nil }
                url = digiKey.productURL(for: query) ?? distributor.searchURL(mpn: query.mpn)
            }
            return url.map { HorizontalPartPageLink(distributor: distributor, url: $0) }
        }
    }
}
