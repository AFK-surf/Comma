import AppKit
import CoreLocation
import Foundation
import MapKit
import MCP

enum MapsTools {
    static let all: [ToolDefinition] = [searchPlaces, directions, open]

    static let searchPlaces = ToolDefinition(
        app: .maps,
        name: "search_places",
        title: "Search places",
        description: "Searches Apple Maps for places or addresses. Pass near (latitude and longitude) to search around a point; this Mac's own location is not used.",
        inputSchema: Schema.object([
            "query": Schema.string("What or where to look for, such as \"coffee\" or an address."),
            "near_latitude": Schema.number("Latitude to search around."),
            "near_longitude": Schema.number("Longitude to search around."),
            "radius_km": Schema.number("Search radius around near, in kilometres. Defaults to 5."),
            "limit": Schema.integer(Schema.limitDescription, minimum: 1, maximum: 25),
        ], required: ["query"]),
        readOnly: true,
        openWorld: true
    ) { arguments, _ in
        let limit = try arguments.limit(default: 10, max: 25)
        let center = try coordinate(arguments, "near_latitude", "near_longitude")
        let radius = (try arguments.double("radius_km") ?? 5) * 1_000
        guard radius > 0, radius <= 1_000_000 else {
            throw ToolFailure.invalidArguments("radius_km", "radius_km must be more than 0 and at most 1000.")
        }
        let items = try await search(arguments.requiredString("query"), center: center, radius: radius)
        return ["places": .array(items.prefix(limit).map { place($0) })]
    }

    static let directions = ToolDefinition(
        app: .maps,
        name: "get_directions",
        title: "Directions",
        description: "Gets the distance and expected travel time between two places from Apple Maps, with turn-by-turn steps for driving and walking. Places are addresses, place names or \"latitude,longitude\".",
        inputSchema: Schema.object([
            "from": Schema.string("Start."),
            "to": Schema.string("Destination."),
            "mode": Schema.string("How to travel. Defaults to driving.", enum: ["driving", "walking", "transit"]),
            "depart_at": Schema.date("Departure time. Defaults to now."),
        ], required: ["from", "to"]),
        readOnly: true,
        openWorld: true
    ) { arguments, _ in
        let mode = try arguments.choice("mode", ["driving", "walking", "transit"], default: "driving")
        let request = MKDirections.Request()
        let from = try await mapItem(arguments.requiredString("from"), field: "from")
        let to = try await mapItem(arguments.requiredString("to"), field: "to")
        request.source = from.item
        request.destination = to.item
        request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        if let depart = try arguments.date("depart_at") { request.departureDate = depart.date }
        let ends: Value = [
            "from": place(from.item, coordinateOnly: from.coordinateOnly),
            "to": place(to.item, coordinateOnly: to.coordinateOnly),
            "mode": .string(mode),
        ]
        do {
            if mode == "transit" {
                // Apple Maps gives transit times, not transit routes, to apps.
                let eta = try await MKDirections(request: request).calculateETA()
                return [
                    "route": ends,
                    "distance_meters": .int(Int(eta.distance)),
                    "travel_seconds": .int(Int(eta.expectedTravelTime)),
                    "depart_at": .string(DateText.dateTime(eta.expectedDepartureDate)),
                    "arrive_at": .string(DateText.dateTime(eta.expectedArrivalDate)),
                ]
            }
            guard let route = try await MKDirections(request: request).calculate().routes.first else {
                throw ToolFailure.notFound("Apple Maps found no route.")
            }
            let steps = route.steps.filter { !$0.instructions.isEmpty }.prefix(30).map { step -> Value in
                ["instruction": .string(step.instructions), "distance_meters": .int(Int(step.distance))]
            }
            return [
                "route": ends,
                "name": .string(route.name),
                "distance_meters": .int(Int(route.distance)),
                "travel_seconds": .int(Int(route.expectedTravelTime)),
                "steps": .array(steps),
            ]
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            throw ToolFailure("not_found", "Apple Maps found no route: \(error.localizedDescription)")
        }
    }

    static let open = ToolDefinition(
        app: .maps,
        name: "open",
        title: "Open in Maps",
        description: "Opens the Maps app on the user's Mac at a place (query) or with directions (from and to).",
        inputSchema: Schema.object([
            "query": Schema.string("A place to show."),
            "from": Schema.string("Directions start. Leave out to start from the user's location."),
            "to": Schema.string("Directions destination."),
            "mode": Schema.string("How to travel.", enum: ["driving", "walking", "transit"]),
        ]),
        readOnly: false
    ) { arguments, _ in
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        var items: [URLQueryItem] = []
        if let to = try arguments.string("to") {
            items.append(URLQueryItem(name: "daddr", value: to))
            if let from = try arguments.string("from") { items.append(URLQueryItem(name: "saddr", value: from)) }
            let mode = try arguments.choice("mode", ["driving", "walking", "transit"], default: "driving")
            items.append(URLQueryItem(name: "dirflg", value: mode == "walking" ? "w" : mode == "transit" ? "r" : "d"))
        } else if let query = try arguments.string("query") {
            items.append(URLQueryItem(name: "q", value: query))
        } else {
            throw ToolFailure.invalidArguments("query", "Pass query, or to (with from if needed).")
        }
        components.queryItems = items
        guard let url = components.url, await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw ToolFailure("app_error", "Maps could not be opened.")
        }
        return ["opened": .bool(true), "url": .string(url.absoluteString)]
    }

    // MARK: - Helpers

    private static func coordinate(_ arguments: Arguments, _ latitudeKey: String, _ longitudeKey: String) throws
        -> CLLocationCoordinate2D?
    {
        let latitude = try arguments.double(latitudeKey)
        let longitude = try arguments.double(longitudeKey)
        guard let latitude, let longitude else {
            if latitude != nil || longitude != nil {
                throw ToolFailure.invalidArguments(latitudeKey, "Pass both \(latitudeKey) and \(longitudeKey).")
            }
            return nil
        }
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(point) else {
            throw ToolFailure.invalidArguments(latitudeKey, "The coordinate is not valid.")
        }
        return point
    }

    private static func search(_ query: String, center: CLLocationCoordinate2D?, radius: Double) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        }
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            throw ToolFailure("app_error", "Apple Maps search failed: \(error.localizedDescription)")
        }
    }

    /// "latitude,longitude", or the first Apple Maps result for the text.
    private static func mapItem(_ text: String, field: String) async throws -> (item: MKMapItem, coordinateOnly: Bool) {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]) {
            let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if CLLocationCoordinate2DIsValid(point) {
                return (MKMapItem(placemark: MKPlacemark(coordinate: point)), true)
            }
        }
        guard let item = try await search(text, center: nil, radius: 0).first else {
            throw ToolFailure.invalidArguments(field, "Apple Maps could not find \(text).")
        }
        return (item, false)
    }

    /// "MKPOICategoryPublicTransport" -> "public_transport".
    static func category(_ raw: String) -> String {
        let name = raw.hasPrefix("MKPOICategory") ? String(raw.dropFirst("MKPOICategory".count)) : raw
        var snake = ""
        for character in name {
            if character.isUppercase, !snake.isEmpty { snake.append("_") }
            snake.append(contentsOf: character.lowercased())
        }
        return snake
    }

    /// A place made from bare coordinates has no name or address; MapKit's title for it is a guess.
    private static func place(_ item: MKMapItem, coordinateOnly: Bool = false) -> Value {
        let placemark = item.placemark
        return [
            "name": coordinateOnly ? .null : .optional(item.name),
            "address": coordinateOnly ? .null : .optional(placemark.title),
            "latitude": .double(placemark.coordinate.latitude),
            "longitude": .double(placemark.coordinate.longitude),
            "phone": .optional(item.phoneNumber),
            "url": .optional(item.url?.absoluteString),
            "category": .optional(item.pointOfInterestCategory.map { category($0.rawValue) }),
        ]
    }
}
