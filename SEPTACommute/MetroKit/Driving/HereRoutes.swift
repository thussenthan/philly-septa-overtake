import Foundation

/// Decodes HERE Routing v8 car routes: duration, length, highway share, and the
/// toll total HERE works out for the route (`return=summary,tolls`,
/// `tolls[summaries]=total`, `spans=functionalClass,length,names`).
public enum HereRoutes {
    public struct Route: Sendable, Equatable {
        public var name: String
        public var seconds: TimeInterval
        public var meters: Double
        public var highwayMeters: Double
        public var toll: Double
        public var tollCurrency: String?
    }


    struct Response: Decodable {
        struct RouteJSON: Decodable { var sections: [Section] }
        struct Section: Decodable {
            var summary: Summary
            var spans: [Span]?
        }
        struct Summary: Decodable {
            var duration: Double
            var length: Double
            var tolls: TollSummary?
        }
        struct TollSummary: Decodable {
            struct Price: Decodable { var value: Double; var currency: String? }
            var total: Price?
        }
        struct Span: Decodable {
            struct Name: Decodable { var value: String }
            var length: Double?
            var functionalClass: Int?
            var names: [Name]?
        }
        var routes: [RouteJSON]
    }

    public static func decode(_ data: Data) -> [Route]? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.routes.map { route -> Route in
            var seconds = 0.0, meters = 0.0, highway = 0.0, toll = 0.0
            var currency: String?
            var lengthByName: [String: Double] = [:]
            for section in route.sections {
                seconds += section.summary.duration
                meters += section.summary.length
                if let total = section.summary.tolls?.total {
                    toll += total.value
                    currency = total.currency ?? currency
                }
                for span in section.spans ?? [] {
                    let length = span.length ?? 0
                    // Functional classes 1 and 2 are motorways and major highways.
                    if let fc = span.functionalClass, fc <= 2 { highway += length }
                    if let name = span.names?.first?.value { lengthByName[name, default: 0] += length }
                }
            }
            // Named after the road it spends longest on, as Apple Maps names routes.
            let name = lengthByName.max { $0.value < $1.value }?.key ?? ""
            return Route(name: name, seconds: seconds, meters: meters, highwayMeters: highway,
                         toll: (toll * 100).rounded() / 100, tollCurrency: currency)
        }
    }
}
