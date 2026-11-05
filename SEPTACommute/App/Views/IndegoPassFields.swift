import SwiftUI

/// Which Indego pass the rider has, as two plain questions rather than a list of
/// Indego's eight product names: do you have a pass (and does it include e-bike
/// rides), and is it the reduced-fare ACCESS version.
struct IndegoPassFields: View {
    @Binding var pass: IndegoPass

    private enum Kind: String, CaseIterable, Identifiable {
        case none, pass, plus
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "No pass"
            case .pass: return "Pass"
            case .plus: return "Pass + e-bikes"
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch pass {
                case .payAsYouGo: return .none
                case .standard, .access: return .pass
                case .plus, .accessPlus: return .plus
                }
            },
            set: { pass = Self.pass(kind: $0, reduced: isReduced) }
        )
    }

    private var isReduced: Bool { pass == .access || pass == .accessPlus }

    private var reduced: Binding<Bool> {
        Binding(get: { isReduced }, set: { pass = Self.pass(kind: kind.wrappedValue, reduced: $0) })
    }

    private static func pass(kind: Kind, reduced: Bool) -> IndegoPass {
        switch kind {
        case .none: return .payAsYouGo
        case .pass: return reduced ? .access : .standard
        case .plus: return reduced ? .accessPlus : .plus
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Indego pass", selection: kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind.wrappedValue != .none {
                Toggle("Reduced fare (ACCESS card)", isOn: reduced)
            }
            Text(pass.passPriceNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
