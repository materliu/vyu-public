import Foundation
import JavaScriptCore
import XCTest
@testable import VYu

/// Synthetic URL and JavaScript checks; no account pages or credentials are loaded.
@MainActor final class BrowserSignInPrivacyTests: XCTestCase {
    func testHistoryOmitsGoogleAccountPagesAndOAuthCredentialParameters() throws {
        for address in ["https://accounts.google.com/", "https://ACCOUNTS.GOOGLE.COM/signin"] {
            XCTAssertFalse(BrowserModel.canRecordVisit(try XCTUnwrap(URL(string: address))))
        }
        for key in ["code", "access_token", "id_token", "refresh_token", "oauth_token",
                    "oauth_verifier", "credential", "SAMLResponse", "ACCESS_TOKEN"] {
            var components = try XCTUnwrap(URLComponents(string: "https://example.test/callback"))
            components.queryItems = [URLQueryItem(name: "ordinary", value: "fixture"),
                                     URLQueryItem(name: key, value: "fixture-marker")]
            XCTAssertFalse(BrowserModel.canRecordVisit(try XCTUnwrap(components.url)), key)
        }
        // Percent encoding must not hide the credential field from the history gate.
        let encoded = try XCTUnwrap(URL(string: "https://example.test/callback?%63ode=fixture-marker"))
        XCTAssertFalse(BrowserModel.canRecordVisit(encoded))
        for address in ["https://example.test/callback#access_token=fixture-marker",
                        "https://example.test/callback#id_token=fixture-marker&state=fixture",
                        "https://example.test/callback#ACCESS_TOKEN=fixture-marker"] {
            XCTAssertFalse(BrowserModel.canRecordVisit(try XCTUnwrap(URL(string: address))))
        }
    }

    func testHistoryStillAllowsOrdinaryWebPagesAndSearchParameters() throws {
        for address in ["https://x.com/", "https://example.test/watch?id=123",
                        "https://example.test/search?q=accounts.google.com&codecs=h264",
                        "https://example.test/article#section",
                        "http://127.0.0.1:8765/direct"] {
            XCTAssertTrue(BrowserModel.canRecordVisit(try XCTUnwrap(URL(string: address))), address)
        }
    }

    func testDiscoveryExitsBeforeAccessingBrowserAPIsOnGoogleSignIn() throws {
        for hostname in ["accounts.google.com", "ACCOUNTS.GOOGLE.COM"] {
            let context = try XCTUnwrap(JSContext())
            let encodedHost = String(data: try JSONEncoder().encode(hostname), encoding: .utf8)!
            context.evaluateScript("""
                var location = { hostname: \(encodedHost) };
                var browserAPIAccesses = 0;
                Object.defineProperty(this, 'window', {
                    get: function() {
                        browserAPIAccesses++;
                        throw new Error('fixture-browser-api-access');
                    }
                });
                """)
            XCTAssertNil(context.exception)
            context.evaluateScript(DiscoveryScript.source(token: UUID().uuidString))
            XCTAssertNil(context.exception, "Sign-in discovery must return before reading the native bridge or wrapping fetch/XHR.")
            XCTAssertEqual(context.objectForKeyedSubscript("browserAPIAccesses")?.toInt32(), 0)
        }
    }
}
