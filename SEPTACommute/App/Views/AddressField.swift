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
    /// A typed address that has been looked up but not yet accepted.
    @State private var pending: (address: String, coordinate: Coordinate)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: role.symbol)
                    .foregroundStyle(Theme.accent)
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
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: search.query) { _, _ in pending = nil }

            if let error = search.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: .leaveNow))
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: error) }
            }

            // Return used to save whatever the first search result was, silently — and
            // "Main Street" resolves to a Main Street, not necessarily the right one.
            if let pending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Is this the one?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pending.address)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Use this address") {
                            onResolved(pending.address, pending.coordinate)
                            self.pending = nil
                            search.query = ""
                            isFocused = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        Button("Not it") { self.pending = nil }
                            .font(.subheadline)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
                pending = (result.address, result.coordinate)
                isFocused = false
            }
            resolving = false
        }
    }
}
