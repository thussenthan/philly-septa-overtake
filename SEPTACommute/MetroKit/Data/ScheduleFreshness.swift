import Foundation

/// Whether the timetable baked into this build has been superseded.
///
/// The app ships its timetable rather than fetching one, which is what makes it
/// answer instantly and offline. The cost is that the data ages, and the app cannot
/// tell how much it has aged from the data alone: SEPTA's feed declares a fortnight
/// of validity, but its rail timetables change a few times a year, so "past the
/// window" and "actually wrong" are months apart. Warning on the first would mean
/// warning almost always.
///
/// So the question is asked directly instead — has SEPTA published a newer feed than
/// the one in this build? — and the answer is a single short string fetched from
/// SEPTA's own GTFS releases. This is the part of that with no networking in it.
public enum ScheduleFreshness {

    /// Where the published feed versions are listed.
    ///
    /// SEPTA distributes the feed as GitHub releases and tags each one with the
    /// feed version, so the tag of the latest release is the current version. The
    /// releases API returns it in a few hundred bytes, against twenty megabytes for
    /// the feed itself — this is a question the app can afford to ask daily.
    public static let releasesURL = URL(string: "https://api.github.com/repos/septadev/GTFS/releases/latest")!

    /// A SEPTA feed version: `v`, then eight digits of date, then a revision digit —
    /// `v202607261` is the first revision published on 2026-07-26.
    ///
    /// Matching the shape matters because everything downstream leans on it. Two
    /// versions compare correctly as plain strings *only* because the format is
    /// fixed-width and date-ordered, and a tag in some other shape would compare
    /// arbitrarily.
    ///
    /// ASCII digits specifically: `isNumber` alone also accepts Eastern Arabic
    /// numerals and vulgar fractions, which would pass the shape check and then
    /// compare against a plain version string in whatever order Unicode dictates.
    public static func isFeedVersion(_ value: String) -> Bool {
        guard value.count == 10, value.hasPrefix("v") else { return false }
        return value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// True when `remote` is a later feed than `bundled`.
    ///
    /// Silent on anything it does not understand, and that is the point. The failure
    /// this guards against is not missing an update — a rider who misses one gets
    /// slightly old times, which for a schedule that changes three times a year is
    /// usually no difference at all. It is telling every rider, every day, that their
    /// app is out of date because SEPTA renamed a tag. So an unparseable version, an
    /// equal one, or an older one all mean no.
    public static func isSuperseded(bundled: String, remote: String) -> Bool {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFeedVersion(bundled), isFeedVersion(remote) else { return false }
        return remote > bundled
    }

    /// The version string out of the releases payload.
    ///
    /// Decoded with a struct rather than by hand so a changed payload is a `nil`
    /// rather than a crash inside a background refresh.
    public static func version(fromReleasesJSON data: Data) -> String? {
        struct Release: Decodable { let tag_name: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        let tag = release.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }
}
