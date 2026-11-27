import Foundation

/// An AMap web link (`uri.amap.com`) as the AMap app's own link. Opened in Safari, the web link loads AMap's page and
/// asks again before it hands over to the app; the app link opens the route or place at once. `nil` for any other
/// link, or a web link without the coordinates the app needs: that one opens as before.
enum MapAppLink {
    static func amapApp(for url: URL) -> URL? {
        guard url.scheme == "https" || url.scheme == "http", url.host?.lowercased() == "uri.amap.com",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let query = { (name: String) in items.first { $0.name == name }?.value }
        let dev = coordinateSystem(query("coordinate"))
        var app = URLComponents()
        app.scheme = "iosamap"
        switch url.path {
        case "/navigation":
            guard let to = query("to").flatMap(Point.init) else { return nil }
            app.host = "path"
            var parameters = [URLQueryItem(name: "sourceApplication", value: "Comma")]
            // Without a start the app starts from where the person is.
            if let from = query("from").flatMap(Point.init) {
                parameters += [URLQueryItem(name: "slat", value: from.lat), URLQueryItem(name: "slon", value: from.lon)]
                if let name = from.name { parameters.append(URLQueryItem(name: "sname", value: name)) }
            }
            parameters += [URLQueryItem(name: "dlat", value: to.lat), URLQueryItem(name: "dlon", value: to.lon)]
            if let name = to.name { parameters.append(URLQueryItem(name: "dname", value: name)) }
            parameters += [URLQueryItem(name: "dev", value: dev), URLQueryItem(name: "t", value: travelMode(query("mode")))]
            app.queryItems = parameters
        case "/marker":
            guard let point = query("position").flatMap(Point.init) else { return nil }
            app.host = "viewMap"
            app.queryItems = [URLQueryItem(name: "sourceApplication", value: "Comma"),
                              URLQueryItem(name: "poiname", value: query("name") ?? point.name ?? ""),
                              URLQueryItem(name: "lat", value: point.lat), URLQueryItem(name: "lon", value: point.lon),
                              URLQueryItem(name: "dev", value: dev)]
        default:
            return nil
        }
        return app.url
    }

    /// The web link's `mode` as the app's `t`: car 0, bus 1, walk 2, ride 3.
    private static func travelMode(_ mode: String?) -> String {
        switch mode {
        case "bus": "1"
        case "walk": "2"
        case "ride": "3"
        default: "0"
        }
    }

    /// The web link's `coordinate` as the app's `dev`: `wgs84` (GPS) is 1, AMap's own GCJ-02 (`gaode`, the default) 0.
    private static func coordinateSystem(_ coordinate: String?) -> String {
        coordinate?.lowercased() == "wgs84" ? "1" : "0"
    }

    /// `lon,lat[,name]`, the web link's order, in the system its `coordinate` names.
    private struct Point {
        let lon: String
        let lat: String
        let name: String?

        init?(_ value: String) {
            let parts = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, Double(parts[0]) != nil, Double(parts[1]) != nil else { return nil }
            lon = parts[0]
            lat = parts[1]
            name = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        }
    }
}
