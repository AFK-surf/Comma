import Foundation
import Network
import UIKit
import WebKit
import XCTest
@testable import Comma

@MainActor
final class CaptchaSheetTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native CAPTCHA did not reach the expected presentation state.")
        throw HostFailure(message: "CAPTCHA fixture timed out")
    }

    func testWebKitAcceptsOnlyTheActiveMainFrameAndCancellationFencesLateMessages() async throws {
        let server = try CaptchaHTTPFixture()
        defer { server.stop() }
        let origin = try await server.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let page = UIViewController()
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let sheet = CaptchaSheet()
        let completed = expectation(description: "Wrong messages cannot finish the challenge")
        completed.isInverted = true
        let task = Task { @MainActor in
            let result = try await sheet.request(url: origin + "/v1/comma/auth/captcha?challenge_id=current&action=email_login", challengeId: "current", audience: origin)
            completed.fulfill()
            return result
        }
        try await wait { page.presentedViewController != nil }
        let navigation = try XCTUnwrap(page.presentedViewController as? UINavigationController)
        let browser = try XCTUnwrap(navigation.topViewController?.view as? WKWebView)
        try await wait { browser.url?.host == "127.0.0.1" && !browser.isLoading }
        _ = try await browser.evaluateJavaScript("""
        window.postMessage({type:'comma.captcha',challengeId:'stale',token:'wrong'},location.origin);
        const child=document.createElement('iframe');
        child.srcdoc="<script>window.webkit.messageHandlers.commaCaptcha.postMessage({type:'comma.captcha',challengeId:'current',token:'child'})<"+"/script>";
        document.body.appendChild(child);
        null;
        """)
        await fulfillment(of: [completed], timeout: 0.2)
        let originBefore = browser.url
        browser.load(URLRequest(url: URL(string: origin + "/other")!))
        try await wait { !browser.isLoading }
        XCTAssertEqual(browser.url, originBefore)
        task.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        // A retired WebView can still run queued script. Its removed handler cannot finish a later operation.
        _ = try? await browser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'current',token:'late'},location.origin)")
        XCTAssertNil(page.presentedViewController)
        let nextCompleted = expectation(description: "The current challenge completes from its own page")
        let next = Task { @MainActor in
            let token = try await CaptchaSheet().request(url: origin + "/v1/comma/auth/captcha?challenge_id=next&action=registration", challengeId: "next", audience: origin)
            nextCompleted.fulfill()
            return token
        }
        try await wait { page.presentedViewController != nil }
        let nextNavigation = try XCTUnwrap(page.presentedViewController as? UINavigationController)
        let nextBrowser = try XCTUnwrap(nextNavigation.topViewController?.view as? WKWebView)
        try await wait { nextBrowser.url?.host == "127.0.0.1" && !nextBrowser.isLoading }
        _ = try? await browser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'next',token:'old-view'},location.origin);null")
        _ = try await nextBrowser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'next',token:'accepted'},location.origin);null")
        await fulfillment(of: [nextCompleted], timeout: 3)
        next.cancel()
        let accepted = try await next.value
        XCTAssertEqual(accepted, "accepted")
    }

    func testRepeatedTerminalCallbacksDuringCloseCannotReleaseTheSuccessorEarly() async throws {
        let server = try CaptchaHTTPFixture()
        defer { server.stop() }
        let origin = try await server.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let page = UIViewController()
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let first = Task { @MainActor in
            try await CaptchaSheet().request(url: origin + "/v1/comma/auth/captcha?challenge_id=first&action=email_login", challengeId: "first", audience: origin)
        }
        defer { first.cancel() }
        try await wait { page.presentedViewController != nil }
        let retiring = try XCTUnwrap(page.presentedViewController as? UINavigationController)
        let oldBrowser = try XCTUnwrap(retiring.topViewController?.view as? WKWebView)
        try await wait { oldBrowser.url?.host == "127.0.0.1" && !oldBrowser.isLoading }
        _ = try await oldBrowser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'first',token:'first-token'},location.origin);null")
        try await wait { retiring.isBeingDismissed }
        // The real cancellation callback races a successful page result while UIKit still owns the retiring sheet.
        first.cancel()
        await Task.yield()
        let completed = expectation(description: "The successor completes after the first sheet is removed")
        let next = Task { @MainActor in
            let token = try await CaptchaSheet().request(url: origin + "/v1/comma/auth/captcha?challenge_id=next&action=registration", challengeId: "next", audience: origin)
            completed.fulfill()
            return token
        }
        defer { next.cancel() }
        let result = try await first.value
        XCTAssertEqual(result, "first-token")
        XCTAssertNil(retiring.presentingViewController)
        try await wait { page.presentedViewController != nil && page.presentedViewController !== retiring }
        let navigation = try XCTUnwrap(page.presentedViewController as? UINavigationController)
        let browser = try XCTUnwrap(navigation.topViewController?.view as? WKWebView)
        try await wait { browser.url?.host == "127.0.0.1" && !browser.isLoading }
        _ = try? await oldBrowser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'next',token:'stale'},location.origin);null")
        _ = try await browser.evaluateJavaScript("window.postMessage({type:'comma.captcha',challengeId:'next',token:'next-token'},location.origin);null")
        await fulfillment(of: [completed], timeout: 3)
        next.cancel()
        let nextResult = try await next.value
        XCTAssertEqual(nextResult, "next-token")
        XCTAssertNil(page.presentedViewController)
    }

    func testCancellationDuringUIKitPresentationWaitsForActualDismissal() async throws {
        let server = try CaptchaHTTPFixture()
        defer { server.stop() }
        let origin = try await server.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let page = CaptchaPresentationProbe()
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let presented = expectation(description: "UIKit completes the owned presentation")
        var task: Task<String?, any Error>?
        var installed: UIViewController?
        page.started = { controller in
            installed = controller
            XCTAssertTrue(controller.isBeingPresented)
            task?.cancel()
        }
        page.completed = { presented.fulfill() }
        task = Task { @MainActor in
            try await CaptchaSheet().request(url: origin + "/v1/comma/auth/captcha?challenge_id=presenting&action=email_login", challengeId: "presenting", audience: origin)
        }
        let result = try await XCTUnwrap(task).value
        XCTAssertNil(result)
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertNil(installed?.presentingViewController)
        XCTAssertNil(page.presentedViewController)
    }

}

private final class CaptchaHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "captcha-test-http")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    let body = "<!doctype html><html><body>Local CAPTCHA fixture</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}


@MainActor
private final class CaptchaPresentationProbe: UIViewController {
    var started: ((UIViewController) -> Void)?
    var completed: (() -> Void)?

    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        super.present(viewControllerToPresent, animated: flag) { [weak self] in
            self?.completed?()
            completion?()
        }
        started?(viewControllerToPresent)
    }
}
