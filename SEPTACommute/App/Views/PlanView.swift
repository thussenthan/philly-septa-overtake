import SwiftUI

/// The main screen: where am I, where am I going, and which train do I take.
struct PlanView: View {
    @EnvironmentObject private var model: CommuteModel
    @State private var showingSettings = false
    @State private var showingDestinationPicker = false
    @State private var showingOriginPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routeSelector
                    if let advice = model.advice, !advice.isEmpty {
                        adviceBanner(advice)
                    }
                    ForEach(model.noteMessages, id: \.self) { note in
                        noteRow(note)
                    }
                    optionsSection
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SEPTA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingDestinationPicker) {
                DestinationPickerView(
                    title: "Going to",
                    selection: Binding(
                        get: { model.target },
                        set: { model.chooseTarget($0) }
                    )
                )
            }
            .sheet(isPresented: $showingOriginPicker) {
                OriginPickerView(
                    selection: Binding(
                        get: { model.source },
                        set: { model.source = $0; model.replan() }
                    )
                )
            }
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
    }

    // MARK: - Route selector

    private var routeSelector: some View {
        VStack(spacing: 0) {
            Button { showingOriginPicker = true } label: {
                selectorRow(
                    symbol: originSymbol,
                    label: "From",
                    value: originDescription,
                    detail: originDetail
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 46)

            Button { showingDestinationPicker = true } label: {
                selectorRow(
                    symbol: "flag.checkered",
                    label: "To",
                    value: model.targetName,
                    detail: targetDetail
                )
            }
            .buttonStyle(.plain)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectorRow(symbol: String, label: String, value: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 22)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var originSymbol: String {
        switch model.source {
        case .currentLocation: return model.currentStation == nil ? "location.fill" : "tram.fill"
        case .station: return "tram.fill"
        case .saved(let place): return place.role.symbol
        }
    }

    private var originDescription: String {
        switch model.source {
        case .currentLocation:
            if let station = model.currentStation { return station.displayName }
            return model.locationStatusSummary ?? "Current location"
        case .station(let id):
            return model.network.station(id)?.displayName ?? id.rawValue
        case .saved(let place):
            return place.name
        }
    }

    private var originDetail: String? {
        switch model.source {
        case .currentLocation:
            if model.currentStation != nil { return "You're at this station" }
            return nil
        case .station(let id):
            return model.network.station(id)?.intersection
        case .saved(let place):
            return place.address
        }
    }

    private var targetDetail: String? {
        switch model.target {
        case .saved(let place):
            // Say why this destination was picked, when the app picked it.
            return model.targetReason ?? place.address
        case .station(let id):
            return model.network.station(id)?.intersection
        case nil:
            return "Pick a destination to get started"
        }
    }

    // MARK: - Advice

    private func adviceBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsSection: some View {
        if model.target == nil {
            MessageCard(
                symbol: "flag.checkered",
                title: "Where are you headed?",
                message: "Pick a destination above and this screen will tell you which train to take, and how long you have to catch it."
            )
        } else if model.resolvedOrigin == nil {
            locationPrompt
        } else if let plan = model.plan, let best = plan.journeys.first {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: plan.journeys.count == 1 ? "Your option" : "\(plan.journeys.count) options")
                ForEach(plan.journeys) { journey in
                    NavigationLink {
                        JourneyDetailView(
                            journey: journey,
                            summary: model.narrator.summary(for: journey),
                            narrator: model.narrator,
                            network: model.network,
                            originName: originDescription,
                            destinationName: model.targetName
                        )
                    } label: {
                        JourneyCardView(
                            journey: journey,
                            summary: model.narrator.summary(for: journey),
                            comparison: model.narrator.comparison(of: journey, against: best),
                            narrator: model.narrator,
                            network: model.network
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if model.plan != nil {
            MessageCard(
                symbol: "moon.zzz",
                title: "Nothing running",
                message: "No trips found in the next hour and a half. Check septa.org for service alerts."
            )
        } else {
            ProgressView("Working out your options…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private var locationPrompt: some View {
        switch model.locationService.status {
        case .denied, .restricted:
            VStack(spacing: 12) {
                MessageCard(
                    symbol: "location.slash",
                    title: "Location is off",
                    message: "Turn on location access to plan from where you are — or pick a starting station instead.",
                    tint: Theme.color(for: .leaveSoon)
                )
                Button("Choose a starting station") { showingOriginPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        case .failed(let message):
            MessageCard(
                symbol: "exclamationmark.triangle",
                title: "Couldn't get your location",
                message: message,
                tint: Theme.color(for: .leaveSoon)
            )
        default:
            VStack(spacing: 12) {
                ProgressView("Finding you…")
                Button("Pick a starting station instead") { showingOriginPicker = true }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let plannedAt = model.lastPlannedAt {
                Text("Updated \(Format.clock(plannedAt))")
            }
            Text(model.scheduleFootnote)
            Text("Scheduled times, not live train positions.")
            if model.hasManualTarget {
                Button("Go back to picking my destination automatically") {
                    model.resumeAutomaticTarget()
                }
                .font(.caption2)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CommuteModel {
    /// A short phrase for the "From" row while location is still settling.
    var locationStatusSummary: String? {
        switch locationService.status {
        case .located: return "Current location"
        case .locating, .requestingPermission: return "Finding you…"
        case .denied, .restricted: return "Location off"
        case .failed: return "Location unavailable"
        case .idle: return "Current location"
        }
    }
}
