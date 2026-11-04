import Foundation
import Security

/// Car routes from HERE Routing v8, with their real toll cost.
///
/// Apple Maps says whether a route has tolls but not what they cost, and offers
/// only a few routes. HERE returns up to six alternatives, each with an itemised
/// toll total for wherever in the world the route goes. It needs the rider's own
/// (free) developer key, kept in the Keychain on this device — the app still has
/// no server of its own.
enum HereRouting {
    struct Route: Equatable {
        var name: String
        var seconds: TimeInterval
        var meters: Double
        var highwayMeters: Double
        var toll: Double
        var tollCurrency: String?
    }

    enum Failure: Error { case badKey, network, decode }

    static func routes(from: Coordinate, to: Coordinate, key: String, avoidTolls: Bool, now: Date) async throws -> [Route] {
        var components = URLComponents(string: "https://router.hereapi.com/v8/routes")!
        let currency = Locale.current.currency?.identifier ?? "USD"
        var items = [
            URLQueryItem(name: "transportMode", value: "car"),
            URLQueryItem(name: "origin", value: "\(from.latitude),\(from.longitude)"),
            URLQueryItem(name: "destination", value: "\(to.latitude),\(to.longitude)"),
            URLQueryItem(name: "departureTime", value: ISO8601DateFormatter().string(from: now)),
            URLQueryItem(name: "return", value: "summary,tolls"),
            URLQueryItem(name: "spans", value: "functionalClass,length,names"),
            URLQueryItem(name: "tolls[summaries]", value: "total"),
            // Priced as with a transponder (E-ZPass and its equivalents).
            URLQueryItem(name: "tolls[transponders]", value: "all"),
            URLQueryItem(name: "currency", value: currency),
            URLQueryItem(name: "apiKey", value: key),
        ]
        if avoidTolls {
            items.append(URLQueryItem(name: "avoid[features]", value: "tollRoad"))
        } else {
            items.append(URLQueryItem(name: "alternatives", value: "6"))
        }
        components.queryItems = items
        guard let url = components.url else { throw Failure.network }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw Failure.badKey
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [Route] {
        guard let routes = HereRoutes.decode(data) else { throw Failure.decode }
        return routes.map {
            Route(name: $0.name, seconds: $0.seconds, meters: $0.meters, highwayMeters: $0.highwayMeters,
                  toll: $0.toll, tollCurrency: $0.tollCurrency)
        }
    }
}

/// The HERE key, in the Keychain rather than UserDefaults: it is a credential.
enum HereKeyStore {
    private static let service = "com.thussenthan.Overtake.here"

    static var key: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
