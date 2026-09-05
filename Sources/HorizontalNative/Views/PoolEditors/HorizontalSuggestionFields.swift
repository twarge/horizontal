import SwiftUI

/// A text field that offers completions from the pool (manufacturers, for
/// one) while typing: a list drops down under the field, arrow keys move
/// through it, Return takes the highlighted entry or what was typed, Escape
/// hides it. Commits on Return or when focus leaves, like
/// `HorizontalCommittedTextField`.
struct HorizontalSuggestingTextField: View {
    var text: String
    var suggestions: [String]
    var isReadOnly: Bool
    var placeholder = ""
    var onCommit: (String) -> Void

    @State private var draft = ""
    @State private var highlighted: Int?
    @State private var suggestionsHidden = false
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        HorizontalSuggestionMatcher.matches(for: draft, in: suggestions, excluding: [])
    }

    private var showsSuggestions: Bool {
        isFocused && !suggestionsHidden && !matches.isEmpty && draft != text
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .disabled(isReadOnly)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
            .onChange(of: draft) { _, _ in
                suggestionsHidden = false
                highlighted = nil
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitIfChanged()
                    highlighted = nil
                }
            }
            .onSubmit {
                if let highlighted, matches.indices.contains(highlighted) {
                    draft = matches[highlighted]
                }
                suggestionsHidden = true
                commitIfChanged()
            }
            .onKeyPress(.downArrow) {
                guard showsSuggestions else {
                    return .ignored
                }
                highlighted = min((highlighted ?? -1) + 1, matches.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard showsSuggestions, let current = highlighted else {
                    return .ignored
                }
                highlighted = current > 0 ? current - 1 : nil
                return .handled
            }
            .onKeyPress(.escape) {
                guard showsSuggestions else {
                    return .ignored
                }
                suggestionsHidden = true
                return .handled
            }
            .overlay(alignment: .topLeading) {
                if showsSuggestions {
                    HorizontalSuggestionList(matches: matches, highlighted: highlighted) { choice in
                        draft = choice
                        suggestionsHidden = true
                        commitIfChanged()
                    }
                    .offset(y: 26)
                }
            }
            .zIndex(showsSuggestions ? 10 : 0)
    }

    private func commitIfChanged() {
        guard draft != text else {
            return
        }
        onCommit(draft)
    }
}

/// Tags as tokens: each a capsule with its own remove button, a field at the
/// end for the next one (space, comma or Return finishes a token, Backspace
/// on an empty field takes the last one back), completions from the pool's
/// existing tags while typing. Every add or remove commits.
struct HorizontalTokenField: View {
    var tokens: [String]
    var suggestions: [String]
    var isReadOnly: Bool
    var placeholder = "Add tag"
    var onCommit: ([String]) -> Void

    @State private var draft = ""
    @State private var highlighted: Int?
    @State private var suggestionsHidden = false
    @FocusState private var isFocused: Bool

    private var matches: [String] {
        HorizontalSuggestionMatcher.matches(for: draft, in: suggestions, excluding: Set(tokens))
    }

    private var showsSuggestions: Bool {
        isFocused && !suggestionsHidden && !draft.isEmpty && !matches.isEmpty
    }

    /// The tokens `text` holds: split at whitespace, commas and semicolons.
    static func tokens(splitting text: String) -> [String] {
        text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        HorizontalFlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                HStack(spacing: 2) {
                    Text(token)
                        .lineLimit(1)
                    if !isReadOnly {
                        Button {
                            var updated = tokens
                            updated.remove(at: index)
                            onCommit(updated)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove “\(token)”")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
            TextField(tokens.isEmpty ? placeholder : "", text: $draft)
                .textFieldStyle(.plain)
                .frame(minWidth: 90)
                .focused($isFocused)
                .disabled(isReadOnly)
                .onChange(of: draft) { _, newValue in
                    suggestionsHidden = false
                    highlighted = nil
                    // A separator finishes the token being typed.
                    if newValue.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
                        addTokens(from: newValue)
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        addTokens(from: draft)
                        highlighted = nil
                    }
                }
                .onSubmit {
                    if let highlighted, matches.indices.contains(highlighted) {
                        add(matches[highlighted])
                    } else {
                        addTokens(from: draft)
                    }
                }
                .onKeyPress(.delete) {
                    guard draft.isEmpty, !tokens.isEmpty, !isReadOnly else {
                        return .ignored
                    }
                    onCommit(Array(tokens.dropLast()))
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard showsSuggestions else {
                        return .ignored
                    }
                    highlighted = min((highlighted ?? -1) + 1, matches.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showsSuggestions, let current = highlighted else {
                        return .ignored
                    }
                    highlighted = current > 0 ? current - 1 : nil
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard showsSuggestions else {
                        return .ignored
                    }
                    suggestionsHidden = true
                    return .handled
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isReadOnly ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.35))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isReadOnly {
                isFocused = true
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsSuggestions {
                HorizontalSuggestionList(matches: matches, highlighted: highlighted) { choice in
                    add(choice)
                }
                .alignmentGuide(.bottom) { _ in 0 }
            }
        }
        .zIndex(showsSuggestions ? 10 : 0)
    }

    private func addTokens(from text: String) {
        let additions = Self.tokens(splitting: text)
        draft = ""
        guard !additions.isEmpty else {
            return
        }
        var updated = tokens
        for token in additions where !updated.contains(token) {
            updated.append(token)
        }
        if updated != tokens {
            onCommit(updated)
        }
    }

    private func add(_ token: String) {
        draft = ""
        suggestionsHidden = true
        guard !tokens.contains(token) else {
            return
        }
        onCommit(tokens + [token])
    }
}

/// The drop-down under a suggesting field.
struct HorizontalSuggestionList: View {
    var matches: [String]
    var highlighted: Int?
    var onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                Button {
                    onChoose(match)
                } label: {
                    Text(match)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum HorizontalSuggestionMatcher {
    /// Up to eight suggestions for `query`: prefix matches first, then
    /// substring matches, case-insensitively; nothing for an empty query.
    static func matches(for query: String, in suggestions: [String], excluding: Set<String>) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return []
        }
        var prefix = [String]()
        var contains = [String]()
        for suggestion in suggestions where !excluding.contains(suggestion) && suggestion.lowercased() != needle {
            let lowered = suggestion.lowercased()
            if lowered.hasPrefix(needle) {
                prefix.append(suggestion)
            } else if lowered.contains(needle) {
                contains.append(suggestion)
            }
        }
        return Array((prefix + contains).prefix(8))
    }
}

/// Wraps its children into rows, the way a tag field lays out tokens.
struct HorizontalFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
