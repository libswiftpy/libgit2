//
//  GitHubAuthorizationTests.swift
//  SwiftPyGit
//

import Foundation
import Testing
@testable import SwiftPyGit

/// GitHub's answer per path, and the form each request sent.
final class MockGitHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var forms: [String: [String: String]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "github.com" || request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // Only a form body: setting percentEncodedQuery to JSON, as creating a
        // repository sends, traps; URLComponents(string:) returns nil instead.
        if request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
           let body = bodyData(),
           let components = URLComponents(string: "?" + String(decoding: body, as: UTF8.self)) {
            Self.forms[path] = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
        let (status, text) = Self.replies[path] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHub.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct GitHubAuthorizationTests {
    private let attempt = GitHubAuthorization.Attempt()
    private let redirect = URL(string: "pyprompt://oauth/github")!

    init() {
        MockGitHub.replies = [:]
        MockGitHub.forms = [:]
    }

    @Test func authorizeURLCarriesStateAndChallenge() throws {
        let url = GitHubAuthorization.authorizeURL(clientID: "client", redirect: redirect, attempt: attempt)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(url.host == "github.com")
        #expect(query["client_id"] == "client")
        #expect(query["redirect_uri"] == "pyprompt://oauth/github")
        #expect(query["scope"] == "repo")
        #expect(query["state"] == attempt.state)
        #expect(query["code_challenge"] == attempt.challenge)
        #expect(query["code_challenge_method"] == "S256")
    }

    @Test func callbackGivesTheCodeOnlyForItsAttempt() throws {
        let ok = URL(string: "pyprompt://oauth/github?code=abc&state=\(attempt.state)")!
        #expect(try GitHubAuthorization.code(from: ok, attempt: attempt) == "abc")

        let other = URL(string: "pyprompt://oauth/github?code=abc&state=other")!
        #expect(throws: GitHubSignInError.stateMismatch) { try GitHubAuthorization.code(from: other, attempt: attempt) }

        let denied = URL(string: "pyprompt://oauth/github?error=access_denied&state=\(attempt.state)")!
        #expect(throws: GitHubSignInError.denied) { try GitHubAuthorization.code(from: denied, attempt: attempt) }
    }

    @Test func exchangesTheCodeWithSecretAndVerifier() async throws {
        MockGitHub.replies["/login/oauth/access_token"] = (200, #"{"access_token":"gho_token","token_type":"bearer","scope":"repo"}"#)
        let token = try await GitHubAuthorization.exchange(
            code: "abc", attempt: attempt, clientID: "client", clientSecret: "s+cret",
            redirect: redirect, session: MockGitHub.session
        )
        #expect(token == "gho_token")
        let form = try #require(MockGitHub.forms["/login/oauth/access_token"])
        #expect(form["client_secret"] == "s+cret")
        #expect(form["code"] == "abc")
        #expect(form["code_verifier"] == attempt.verifier)
    }

    @Test func aRefusedExchangeIsAnError() async throws {
        MockGitHub.replies["/login/oauth/access_token"] = (200, #"{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}"#)
        await #expect(throws: GitHubSignInError.oauth(code: "bad_verification_code", description: "The code passed is incorrect or expired.")) {
            try await GitHubAuthorization.exchange(
                code: "abc", attempt: attempt, clientID: "client", clientSecret: "secret",
                redirect: redirect, session: MockGitHub.session
            )
        }
    }

    @Test func readsTheLogin() async throws {
        MockGitHub.replies["/user"] = (200, #"{"login":"octocat","id":1}"#)
        let login = try await GitHubAuthorization.login(token: "gho_token", session: MockGitHub.session)
        #expect(login == "octocat")
    }

    @Test func createsARepository() async throws {
        MockGitHub.replies["/user/repos"] = (201, #"{"name":"demo","clone_url":"https://github.com/octocat/demo.git"}"#)
        let url = try await GitHubAuthorization.createRepository(name: "demo", isPrivate: true, token: "gho_token", session: MockGitHub.session)
        #expect(url == "https://github.com/octocat/demo.git")
    }

    @Test func aTakenNameIsAClearError() async throws {
        MockGitHub.replies["/user/repos"] = (422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#)
        await #expect(throws: GitHubSignInError.repository("name already exists on this account")) {
            try await GitHubAuthorization.createRepository(name: "demo", isPrivate: true, token: "gho_token", session: MockGitHub.session)
        }
    }
}
