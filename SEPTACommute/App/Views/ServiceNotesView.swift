import SwiftUI

/// Everything the home screen deliberately doesn't say.
///
/// SEPTA's alert text, the planner's caveats, and where the timetable came from.
/// All of it matters some of the time and none of it changes which train to catch,
/// so it lives one tap away rather than above the answer.
struct ServiceNotesView: View {
    @EnvironmentObject private var model: CommuteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !model.serviceAlerts.isEmpty {
                    Section("From SEPTA") {
                        ForEach(model.serviceAlerts) { alert in
                            alertRow(alert)
                        }
                    }
                }

                if let problem = model.alertFetchProblem {
                    Section {
                        Label(problem, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.noteMessages.isEmpty {
                    Section("About these options") {
                        ForEach(model.noteMessages, id: \.self) { note in
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.fareNotes.isEmpty {
                    Section("Fares") {
                        ForEach(model.fareNotes, id: \.self) { note in
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !model.estimatedTimeNotes.isEmpty {
                    Section("How exact these times are") {
                        ForEach(model.estimatedTimeNotes, id: \.self) { note in
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Timetable") {
                    Text(model.scheduleFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Scheduled times, not live train positions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let live = model.liveDataNote {
                        Text(live)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let plannedAt = model.lastPlannedAt {
                        Text("Options worked out at \(Format.clock(plannedAt)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.serviceAlerts.isEmpty, model.alertFetchProblem == nil {
                    Section {
                        Label("SEPTA isn't reporting anything on your lines.", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Service & data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func alertRow(_ alert: ServiceAlert) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let lineID = alert.lineID, let line = model.network.line(lineID) {
                    LineBadge(
                        text: line.badge,
                        color: Theme.color(for: line),
                        textColor: Theme.foreground(on: line),
                        size: 20
                    )
                } else {
                    Image(systemName: "megaphone.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(alert.severity.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.color(for: alert.severity))
                Text(alert.routeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(alert.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

extension Theme {
    /// Alert severities borrow the urgency palette: a suspension is as red as a
    /// train about to leave without you.
    static func color(for severity: AlertSeverity) -> Color {
        switch severity {
        case .advisory: return .secondary
        case .detour, .delay: return color(for: Urgency.Level.leaveSoon)
        case .modifiedService, .suspended: return color(for: Urgency.Level.leaveNow)
        }
    }
}
