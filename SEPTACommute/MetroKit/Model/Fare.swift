import Foundation

/// What a trip costs, from SEPTA's own fare tables.
///
/// The flat fare is the boring half. The interesting half is the transfer: SEPTA's
/// `fare_transfer_rules` give free transfers within two hours on SEPTA Key and
/// contactless, and no such rule for cash or Quick Trip. So the same two-train
/// itinerary is $2.90 or $5.80 depending on how you tapped in, which is the one
/// fare fact that can change which option a rider picks.
public struct FareRules: Sendable, Hashable {
    /// One pay-per-ride boarding, adult full fare.
    public var amount: Double
    /// ISO currency code, for formatting.
    public var currency: String
    /// How long a free transfer stays valid.
    public var transferWindow: TimeInterval
    /// How many free transfers one fare covers.
    public var includedTransfers: Int
    /// Payment methods that get the free transfer, named as SEPTA names them.
    public var freeTransferMedia: [String]
    /// Payment methods that charge for every boarding.
    public var perBoardingMedia: [String]

    public init(
        amount: Double,
        currency: String = "USD",
        transferWindow: TimeInterval = 0,
        includedTransfers: Int = 0,
        freeTransferMedia: [String] = [],
        perBoardingMedia: [String] = []
    ) {
        self.amount = amount
        self.currency = currency
        self.transferWindow = transferWindow
        self.includedTransfers = includedTransfers
        self.freeTransferMedia = freeTransferMedia
        self.perBoardingMedia = perBoardingMedia
    }

    /// True when the operator publishes anything useful.
    public var isKnown: Bool { amount > 0 }
}

/// What one journey costs under those rules.
public struct JourneyFare: Sendable, Hashable {
    /// Number of times the rider taps in.
    public var boardings: Int
    /// Total paying with a medium that includes transfers.
    public var withFreeTransfers: Double
    /// Total paying for each boarding separately.
    public var perBoarding: Double
    /// False when the journey has more changes, or takes longer, than one fare covers.
    public var transfersAreCovered: Bool

    public var currency: String

    /// True when how you pay changes what you pay.
    public var mediumMatters: Bool { perBoarding > withFreeTransfers + 0.005 }
}

public extension Journey {
    /// What this journey costs. `nil` for a walk — there is nothing to pay.
    func fare(_ rules: FareRules) -> JourneyFare? {
        guard rules.isKnown, !rides.isEmpty else { return nil }
        let boardings = rides.count
        let transfers = boardings - 1

        // The window runs from the first fare validation to the last, which for a
        // rider tapping as they board is first departure to last departure.
        let spread = (rides.last?.departure ?? Date()).timeIntervalSince(rides.first?.departure ?? Date())
        let covered = transfers <= rules.includedTransfers
            && (rules.transferWindow <= 0 || spread <= rules.transferWindow)

        // Beyond the allowance the rider starts a second fare, and its own transfers
        // are covered in turn.
        let faresNeeded = covered ? 1 : Int(ceil(Double(boardings) / Double(max(1, rules.includedTransfers + 1))))

        return JourneyFare(
            boardings: boardings,
            withFreeTransfers: rules.amount * Double(faresNeeded),
            perBoarding: rules.amount * Double(boardings),
            transfersAreCovered: covered,
            currency: rules.currency
        )
    }
}

public extension Format {
    /// "$2.90", in the rider's locale but the operator's currency.
    static func money(_ amount: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = .autoupdatingCurrent
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}
