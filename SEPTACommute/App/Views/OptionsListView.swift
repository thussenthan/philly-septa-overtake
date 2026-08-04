import SwiftUI

/// Every option the planner found, in full.
///
/// The home screen shows the answer and the two nearest alternatives; this is where
/// a rider goes when they want to see the whole set — the "half and half" routes,
/// the slower one that leaves much later, the walk.
struct OptionsListView: View {
    @EnvironmentObject private var model: CommuteModel
    var originName: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // The one sentence that says which to take. It belongs here rather
                // than on the home screen, where the recommendation is already the
                // largest thing on it — here the rider is comparing, and a summary
                // of the comparison is the useful thing to lead with.
                if let advice = model.advice, !advice.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Theme.accent)
                        Text(advice)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }

                if let plan = model.plan, let best = plan.journeys.first {
                    ForEach(plan.journeys) { journey in
                        NavigationLink {
                            JourneyDetailView(
                                journey: journey,
                                summary: model.narrator.summary(for: journey),
                                narrator: model.narrator,
                                network: model.network,
                                originName: originName,
                                destinationName: model.targetName,
                                alert: model.alert(for: journey)
                            )
                        } label: {
                            JourneyCardView(
                                journey: journey,
                                summary: model.narrator.summary(for: journey),
                                comparison: model.narrator.comparison(of: journey, against: best),
                                narrator: model.narrator,
                                network: model.network,
                                alertLabel: model.alert(for: journey).map { model.alertChipText($0) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("All options")
        .navigationBarTitleDisplayMode(.inline)
    }
}
