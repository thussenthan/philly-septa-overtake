import SwiftUI

/// An address entry field with Philadelphia-biased autocomplete.
///
/// Used by onboarding and settings so the rider types their address exactly once
/// and the app keeps the coordinate rather than re-geocoding later.
struct AddressField: View {
    var role: SavedPlace.Role
    var prompt: String
    /// Called with the confirmed address and coordinate.
    var onResolved: (String, Coordinate) -> Void

    @StateObject private var search = AddressSearch()
    @FocusState private var isFocused: Bool
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: role.symbol)
                    .foregroundStyle(Theme.broadStreet)
                    .frame(width: 22)
                TextField(prompt, text: $search.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit { resolveTypedText() }
                if resolving {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))

            if let error = search.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: .leaveNow))
            }

            if !search.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(search.suggestions.prefix(5)) { suggestion in
                        Button {
                            resolve(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if suggestion != search.suggestions.prefix(5).last {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func resolve(_ suggestion: AddressSearch.Suggestion) {
        resolving = true
        Task {
            if let result = await search.resolve(suggestion) {
                onResolved(result.address, result.coordinate)
                search.query = ""
                isFocused = false
            }
            resolving = false
        }
    }

    private func resolveTypedText() {
        resolving = true
        Task {
            if let result = await search.resolveRawQuery() {
                onResolved(result.address, result.coordinate)
                search.query = ""
                isFocused = false
            }
            resolving = false
        }
    }
}
