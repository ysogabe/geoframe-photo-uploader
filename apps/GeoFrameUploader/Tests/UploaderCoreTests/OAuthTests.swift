import XCTest
@testable import UploaderCore

final class OAuthTests: XCTestCase {
    let client = OAuthClientConfig(clientId: "cid.apps.googleusercontent.com", clientSecret: "sec")

    func testPKCEKnownVector() {
        // RFC 7636 Appendix B
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierShape() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<20 {
            let v = PKCE.makeVerifier()
            XCTAssertTrue((43...128).contains(v.count), "\(v.count)")
            XCTAssertTrue(v.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
        XCTAssertNotEqual(PKCE.makeVerifier(), PKCE.makeVerifier())
        XCTAssertGreaterThanOrEqual(PKCE.randomState().count, 43)
    }

    func testAuthorizationURL() {
        let url = OAuthURLBuilder.authorizationURL(client: client, redirectURI: "http://127.0.0.1:53123",
                                                   scopes: GoogleAuth.scopes, codeChallenge: "CH", state: "ST")
        XCTAssertEqual(url.host, "accounts.google.com")
        let q = FormEncoding.parseQuery(url.query(percentEncoded: true)!)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], client.clientId)
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:53123")
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/drive")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["code_challenge"], "CH")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "ST")
        XCTAssertNil(q["client_secret"])
        XCTAssertTrue(url.query(percentEncoded: true)!.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A53123"))
    }

    func testCallbackParsing() {
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/?state=ST&code=4%2F0Abc&scope=x", expectedState: "ST"), .success("4/0Abc"))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/?state=EVIL&code=4%2F0Abc", expectedState: "ST"), .failure(.stateMismatch))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/?code=4%2F0Abc", expectedState: "ST"), .failure(.stateMismatch))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/?state=ST", expectedState: "ST"), .failure(.missingCode))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/?state=ST&error=access_denied", expectedState: "ST"),
                       .failure(.authorizationDenied("access_denied")))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/favicon.ico", expectedState: "ST"), .failure(.notCallback))
        XCTAssertEqual(OAuthCallback.parse(requestTarget: "/", expectedState: "ST"), .failure(.notCallback))
        XCTAssertEqual(OAuthCallback.requestTarget(fromRawRequest: "GET /?a=b HTTP/1.1\r\nHost: x\r\n\r\n"), "/?a=b")
        XCTAssertNil(OAuthCallback.requestTarget(fromRawRequest: "POST / HTTP/1.1\r\n\r\n"))
    }

    func testLoopbackServerAcceptsOnlyValidCallback() async throws {
        let server = LoopbackServer(expectedState: "ST")
        let port = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        // 無関係・不正 state のリクエストは無視される
        let (_, r1) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 404)
        let (_, r2) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/?state=BAD&code=x")!)
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 400)
        let (body, r3) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/?state=ST&code=GOOD")!)
        XCTAssertEqual((r3 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("認可が完了しました"))
        let code = try await server.waitForCode(timeout: 5)
        XCTAssertEqual(code, "GOOD")
    }

    func testLoopbackTimeout() async throws {
        let server = LoopbackServer(expectedState: "ST")
        _ = try await server.start()
        do { _ = try await server.waitForCode(timeout: 0.2); XCTFail() } catch let e as LoopbackError {
            guard case .timeout = e else { return XCTFail("\(e)") }
        }
    }

    func testRefreshFlowUsesStoreAndCachesToken() async throws {
        var calls = 0
        StubProtocol.setHandler { r in
            calls += 1
            XCTAssertEqual(r.url.absoluteString, "https://oauth2.googleapis.com/token")
            let p = FormEncoding.parseQuery(String(decoding: r.body, as: UTF8.self))
            XCTAssertEqual(p["grant_type"], "refresh_token")
            XCTAssertEqual(p["refresh_token"], "RT")
            XCTAssertEqual(p["client_id"], "cid.apps.googleusercontent.com")
            return .http(200, [:], json(["access_token": "AT\(calls)", "expires_in": 3600, "token_type": "Bearer"]))
        }
        let store = InMemoryTokenStore(token: "RT")
        let auth = GoogleAuth(client: client, store: store, session: StubProtocol.session())
        let a1 = try await auth.accessToken()
        let a2 = try await auth.accessToken()
        XCTAssertEqual(a1, "AT1")
        XCTAssertEqual(a2, "AT1")            // キャッシュ
        let a3 = try await auth.refreshAfterUnauthorized()
        XCTAssertEqual(a3, "AT2")
        XCTAssertEqual(calls, 2)
    }

    func testInvalidGrantRequiresReauth() async throws {
        StubProtocol.setHandler { _ in .http(400, [:], json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."])) }
        let auth = GoogleAuth(client: client, store: InMemoryTokenStore(token: "RT"), session: StubProtocol.session())
        do { _ = try await auth.accessToken(); XCTFail() } catch let e as GoogleAuthError {
            guard case .reauthRequired = e else { return XCTFail("\(e)") }
        }
        let none = GoogleAuth(client: client, store: InMemoryTokenStore(), session: StubProtocol.session())
        do { _ = try await none.accessToken(); XCTFail() } catch let e as GoogleAuthError {
            guard case .notSignedIn = e else { return XCTFail("\(e)") }
        }
    }

    func testSignOutDeletesAndRevokes() async {
        StubProtocol.setHandler { _ in .http(200, [:], Data()) }
        let store = InMemoryTokenStore(token: "RT")
        await GoogleAuth.signOut(store: store, session: StubProtocol.session())
        XCTAssertFalse(store.exists())
        XCTAssertEqual(StubProtocol.recorded.first?.url.absoluteString, "https://oauth2.googleapis.com/revoke")
    }
}
