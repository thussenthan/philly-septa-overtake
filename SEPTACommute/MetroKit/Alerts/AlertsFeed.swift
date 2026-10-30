import Foundation

/// Turns SEPTA's alerts endpoint into `ServiceAlert`s.
///
/// The decoding lives here, in the data layer, rather than next to the networking
/// code: the interesting part is the mapping from SEPTA's route naming to the
/// lines this app models, and that is worth testing against a captured response
/// rather than against the live feed.
///
/// The endpoint is `https://www3.septa.org/api/Alerts/index.php` — plain JSON, an
/// array with one entry per route, whether or not anything is wrong with it. So
/// most of the work is throwing away the 180-odd entries that say "nothing to
/// report" and the routes this app doesn't carry.
public enum AlertsFeed {

    /// Decodes to nil rather than throwing, so the array survives a bad element.
    private struct Lossy: Decodable {
        let entry: RawEntry?
        init(from decoder: Decoder) throws {
            entry = try? RawEntry(from: decoder)
        }
    }

    public enum DecodingProblem: Error, Sendable {
        /// The body parsed as JSON but wasn't the array of route entries expected.
        case unexpectedShape
    }

    /// Every alert in the response that touches a line this app models.
    ///
    /// Entries for buses, Regional Rail, CCT and the mobile app are dropped —
    /// nothing in this app can route over them, so an alert about them is noise.
    public static func decode(_ data: Data, fetchedAt: Date) throws -> AlertDigest {
        let raw: [RawEntry]
        do {
            // Entry by entry: one malformed element costs that alert, not the lot.
            raw = try JSONDecoder().decode([Lossy].self, from: data).compactMap(\.entry)
        } catch is DecodingError {
            throw DecodingProblem.unexpectedShape
        }

        var alerts: [ServiceAlert] = []
        var seen = Set<String>()
        for entry in raw {
            for alert in entry.alerts() where seen.insert(alert.id).inserted {
                alerts.append(alert)
            }
        }
        return AlertDigest(alerts: alerts, fetchedAt: fetchedAt)
    }

    // MARK: - Route mapping

    /// What a SEPTA `route_id` means to this app.
    enum Scope: Equatable {
        case line(LineID)
        /// A notice about the whole system rather than one route.
        case system
        /// A route this app doesn't model, so an alert about it can't be acted on.
        case unmodelled
    }

    /// SEPTA's `route_id` values for the services this app carries.
    ///
    /// The prefixes are the operator's own filing cabinet rather than a description
    /// of the mode: the subway lines are filed under `rr_` alongside Regional Rail,
    /// and Route 15 is under `bus_` because it is currently running as a bus.
    static let scopesByRouteID: [String: Scope] = [
        "rr_route_bsl": .line("B"),
        "rr_route_bso": .line("B-OWL"),
        "rr_route_mfl": .line("L"),
        // The Market-Frankford Owl is the same corridor overnight, and this app will
        // happily plan an L trip at 3am, so its alerts belong on the L.
        "rr_route_mfo": .line("L"),
        "rr_route_nhsl": .line("M"),
        // The five subway-surface trolleys are one line on the map (T1–T5) but five
        // routes in the feed, under their historic numbers.
        "trolley_route_10": .line("T"),
        "trolley_route_34": .line("T"),
        "trolley_route_13": .line("T"),
        "trolley_route_11": .line("T"),
        "trolley_route_36": .line("T"),
        "trolley_route_101": .line("D"),
        "trolley_route_102": .line("D"),
        // Girard. Bussed at the time of writing; keep both spellings so restoring
        // the trolley doesn't silently drop its alerts.
        "bus_route_15": .line("G"),
        "trolley_route_15": .line("G"),
        "bus_route_59": .line("59"),
        "bus_route_66": .line("66"),
        "bus_route_75": .line("75"),
        "generic": .system,
    ]

    static func scope(forRouteID routeID: String) -> Scope {
        scopesByRouteID[routeID.lowercased()] ?? .unmodelled
    }
}

// MARK: - The wire format

/// One route's entry in the alerts response.
///
/// Every field is decoded leniently. This is a third-party feed with no published
/// schema, and one renamed key or one string where an array used to be should cost
/// the app that alert — not the whole screen.
struct RawEntry: Decodable {
    var routeID: String
    var routeName: String
    var mode: String
    var flags: [String: String]
    /// Service-alert text, HTML.
    var alert: String
    /// Advisory text, HTML.
    var advisory: String
    var detours: [RawDetour]
    var lastUpdated: String?

    private enum CodingKeys: String, CodingKey {
        case routeID = "route_id"
        case routeName = "route_name"
        case mode
        case alert, advisory, detour
        case lastUpdated = "last_updated"
        case isadvisory, isalert, isdetour, isdetouralert, isdiversion
        case isdelays, ismodifiedservice, issuspended, isstrike
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeID = (try? container.decode(String.self, forKey: .routeID)) ?? ""
        routeName = (try? container.decode(String.self, forKey: .routeName)) ?? routeID
        mode = (try? container.decode(String.self, forKey: .mode)) ?? ""
        alert = (try? container.decode(String.self, forKey: .alert)) ?? ""
        advisory = (try? container.decode(String.self, forKey: .advisory)) ?? ""
        detours = (try? container.decode([RawDetour].self, forKey: .detour)) ?? []
        lastUpdated = try? container.decode(String.self, forKey: .lastUpdated)

        // SEPTA spells most of these "Y"/"N" but `isadvisory` "Yes"/"No", so they
        // are read through one truthiness rule rather than compared literally.
        var flags: [String: String] = [:]
        for key in [
            CodingKeys.isadvisory, .isalert, .isdetour, .isdetouralert, .isdiversion,
            .isdelays, .ismodifiedservice, .issuspended, .isstrike,
        ] {
            if let value = try? container.decode(String.self, forKey: key) {
                flags[key.stringValue] = value
            }
        }
        self.flags = flags
    }

    private func isSet(_ key: String) -> Bool {
        guard let first = flags[key]?.trimmingCharacters(in: .whitespaces).first else { return false }
        return first == "Y" || first == "y"
    }

    /// The worst thing this entry claims, ignoring detours — those are reported
    /// per detour, each with its own text.
    private var headlineSeverity: AlertSeverity? {
        if isSet("issuspended") || isSet("isstrike") { return .suspended }
        if isSet("ismodifiedservice") { return .modifiedService }
        if isSet("isdelays") { return .delay }
        if isSet("isalert") { return .advisory }
        return nil
    }

    /// One `ServiceAlert` per piece of text, so a line running late *and* on
    /// diversion produces two rows rather than one that mentions only the worse.
    func alerts() -> [ServiceAlert] {
        let scope = AlertsFeed.scope(forRouteID: routeID)
        let lineID: LineID?
        switch scope {
        case .line(let id): lineID = id
        case .system: lineID = nil
        case .unmodelled: return []
        }

        let name = routeName.isEmpty ? mode : routeName
        var results: [ServiceAlert] = []

        func add(_ severity: AlertSeverity, _ text: String) {
            let cleaned = HTMLText.plain(text)
            guard !cleaned.isEmpty else { return }
            results.append(
                ServiceAlert(
                    lineID: lineID,
                    severity: severity,
                    message: cleaned,
                    routeName: name,
                    lastUpdated: lastUpdated
                )
            )
        }

        let headline = headlineSeverity
        add(headline ?? .advisory, alert)
        if isSet("isadvisory") { add(.advisory, advisory) }
        if isSet("isdetour") || isSet("isdetouralert") || isSet("isdiversion") {
            for detour in detours { add(.detour, detour.describedForRider()) }
        }

        // A flag raised with no text still matters — "suspended" is worth saying
        // even when SEPTA left the message blank — but only for the severities a
        // rider would change plans over. A bare `isalert` with nothing to say is
        // nothing to say.
        if results.isEmpty, let headline, headline >= .delay {
            add(headline, "\(name): \(headline.label.lowercased()). Check septa.org for details.")
        }
        return results
    }
}

/// One detour within a route's entry.
struct RawDetour: Decodable {
    var message: String?
    var reason: String?
    var startLocation: String?

    private enum CodingKeys: String, CodingKey {
        case message, reason
        case startLocation = "location_start"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decode(String.self, forKey: .message)
        reason = try? container.decode(String.self, forKey: .reason)
        startLocation = try? container.decode(String.self, forKey: .startLocation)
    }

    /// The detour message, with SEPTA's cause appended when it adds anything.
    ///
    /// The `message` field is written for riders ("SB via 17th Street, Left on
    /// Cecil B. Moore…"); `reason` is the works order ("Crossover Reconstruction
    /// Project"). Both are useful, and neither repeats the other.
    func describedForRider() -> String {
        let body = (message ?? startLocation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty,
              !body.localizedCaseInsensitiveContains(reason) else { return body }
        return "\(body) (\(reason))"
    }
}

// MARK: - HTML

/// Just enough HTML handling to put SEPTA's alert text in a `Text`.
///
/// `NSAttributedString`'s HTML importer would do this properly, but it is not
/// available to a Foundation-only target and has to run on the main thread — for
/// turning `<p>Trains are delayed&nbsp;20 minutes.</p>` into a sentence, that is a
/// poor trade.
enum HTMLText {
    /// Longest message worth putting on a card. SEPTA occasionally pastes whole
    /// tables of shuttle times into one field.
    static let maximumLength = 400

    static func plain(_ html: String) -> String {
        guard !html.isEmpty else { return "" }

        var text = html
        // Structural tags become spaces so words either side don't run together;
        // the whitespace collapse below tidies up after them.
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</tr>"] {
            text = text.replacingOccurrences(of: tag, with: " ", options: .caseInsensitive)
        }
        text = stripTags(from: text)
        text = decodeEntities(in: text)
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard text.count > maximumLength else { return text }
        let cut = text.prefix(maximumLength)
        // Break at a word so the ellipsis doesn't land mid-word.
        let trimmed = cut.lastIndex(of: " ").map { cut[cut.startIndex..<$0] } ?? cut
        return String(trimmed) + "…"
    }

    private static func stripTags(from text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default: if depth == 0 { output.append(character) }
            }
        }
        return output
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
        "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
        "&bull;": "•", "&deg;": "°",
    ]

    private static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var output = text
        for (entity, replacement) in namedEntities {
            output = output.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return decodeNumericEntities(in: output)
    }

    /// `&#39;` and `&#x27;` — SEPTA's CMS emits both.
    private static func decodeNumericEntities(in text: String) -> String {
        guard text.contains("&#") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var rest = Substring(text)

        while let start = rest.range(of: "&#") {
            output += rest[rest.startIndex..<start.lowerBound]
            let afterHash = rest[start.upperBound...]
            guard let end = afterHash.firstIndex(of: ";") else {
                output += rest[start.lowerBound...]
                return output
            }
            let digits = afterHash[afterHash.startIndex..<end]
            let isHex = digits.first == "x" || digits.first == "X"
            let value = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10)
            if let value, let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else {
                output += rest[start.lowerBound...end]
            }
            rest = afterHash[afterHash.index(after: end)...]
        }
        return output + String(rest)
    }
}
