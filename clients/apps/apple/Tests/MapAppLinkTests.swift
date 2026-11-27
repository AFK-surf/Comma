@testable import Comma
import XCTest

final class MapAppLinkTests: XCTestCase {
    private func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testNavigationOpensTheRouteInTheApp() throws {
        let web = try XCTUnwrap(URL(string:
            "https://uri.amap.com/navigation?from=113.615568,22.352055,%E6%88%91&to=113.558421,22.278333,%E7%9B%92%E9%A9%AC&mode=walk&policy=1&src=comma&coordinate=gaode&callnative=1"))
        let app = MapAppLink.amapApp(for: web)
        XCTAssertEqual(app?.scheme, "iosamap")
        XCTAssertEqual(app?.host, "path")
        XCTAssertEqual(query(app), [
            "sourceApplication": "Comma", "slat": "22.352055", "slon": "113.615568", "sname": "我",
            "dlat": "22.278333", "dlon": "113.558421", "dname": "盒马", "dev": "0", "t": "2",
        ])
    }

    func testNavigationWithoutAStartStartsWhereThePersonIs() throws {
        let web = try XCTUnwrap(URL(string: "https://uri.amap.com/navigation?to=113.558421,22.278333&mode=car"))
        let app = query(MapAppLink.amapApp(for: web))
        XCTAssertNil(app["slat"])
        XCTAssertEqual(app["dlat"], "22.278333")
        XCTAssertEqual(app["t"], "0")
    }

    func testGPSCoordinatesAreMarkedForTheAppToConvert() throws {
        let route = try XCTUnwrap(URL(string: "https://uri.amap.com/navigation?to=113.558421,22.278333&coordinate=wgs84"))
        XCTAssertEqual(query(MapAppLink.amapApp(for: route))["dev"], "1")
        let marker = try XCTUnwrap(URL(string: "https://uri.amap.com/marker?position=113.558421,22.278333&coordinate=wgs84"))
        XCTAssertEqual(query(MapAppLink.amapApp(for: marker))["dev"], "1")
    }

    func testMarkerOpensThePlace() throws {
        let web = try XCTUnwrap(URL(string: "https://uri.amap.com/marker?position=113.558421,22.278333&name=%E7%9B%92%E9%A9%AC"))
        let app = MapAppLink.amapApp(for: web)
        XCTAssertEqual(app?.host, "viewMap")
        XCTAssertEqual(query(app)["poiname"], "盒马")
        XCTAssertEqual(query(app)["lon"], "113.558421")
    }

    func testOtherLinksOpenAsBefore() {
        XCTAssertNil(MapAppLink.amapApp(for: URL(string: "https://www.amap.com/search?query=x")!))
        XCTAssertNil(MapAppLink.amapApp(for: URL(string: "https://uri.amap.com/navigation?to=not,a-point")!))
        XCTAssertNil(MapAppLink.amapApp(for: URL(string: "https://www.google.com/maps/dir/?api=1&destination=x")!))
    }
}
