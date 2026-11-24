//
//  GitHubAuthorization.swift
//  SwiftPyGit
//

import CryptoKit
import Foundation
import Security

/// GitHub's OAuth web flow, with PKCE and state on top of the app's secret:
/// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
enum GitHubAuthorization {
    static let authorizeURL = URL(string: "https://github.com/login/oauth/authorize")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let userURL = URL(string: "https://api.github.com/user")!
    // read:org lists the organizations Publish offers.
    static let scope = "repo read:org"

    /// One attempt's secrets, fresh each time.
    struct Attempt {
        var state = randomToken()
        var verifier = randomToken()

        var challenge: String {
            Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    static func authorizeURL(clientID: String, redirect: URL, attempt: Attempt) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "code_challenge", value: attempt.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "allow_signup", value: "true"),
        ]
        return components.url!
    }

    /// The code from the callback, after checking it belongs to this attempt.
    static func code(from callback: URL, attempt: Attempt) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["state"] == attempt.state else { throw GitHubSignInError.stateMismatch }
        if query["error"] == "access_denied" { throw GitHubSignInError.denied }
        if let error = query["error"] {
            throw GitHubSignInError.oauth(code: error, description: query["error_description"] ?? "")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw GitHubSignInError.oauth(code: "missing_code", description: "")
        }
        return code
    }

    /// GitHub answers 200 with either a token or an error.
    private struct TokenReply: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    static func exchange(
        code: String, attempt: Attempt, clientID: String, clientSecret: String,
        redirect: URL, session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "code_verifier", value: attempt.verifier),
        ]
        // URLComponents leaves "+" alone, which a form body reads as a space.
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, _) = try await session.data(for: request)
        let reply = try JSONDecoder().decode(TokenReply.self, from: data)
        if let token = reply.accessToken { return token }
        throw GitHubSignInError.oauth(code: reply.error ?? "invalid_response", description: reply.errorDescription ?? "")
    }

    private struct User: Decodable {
        let login: String
    }

    /// The token's account name.
    static func login(token: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: userURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubSignInError.oauth(code: "user_unavailable", description: "")
        }
        return try JSONDecoder().decode(User.self, from: data).login
    }
}

extension GitHubAuthorization {
    static let repositoriesURL = URL(string: "https://api.github.com/user/repos")!
    static let organizationsURL = URL(string: "https://api.github.com/user/orgs?per_page=100")!

    private struct Organization: Decodable { let login: String }

    /// The organizations the token may act in; empty for a token from before read:org.
    static func organizations(token: String, session: URLSession) async throws -> [String] {
        var request = URLRequest(url: organizationsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw GitHubSignInError.notSignedIn }
        guard status == 200 else { return [] }
        return try JSONDecoder().decode([Organization].self, from: data).map(\.login)
    }

    private struct CreatedRepository: Decodable {
        let cloneURL: String
        enum CodingKeys: String, CodingKey { case cloneURL = "clone_url" }
    }

    private struct APIError: Decodable {
        let message: String?
        let errors: [Detail]?
        struct Detail: Decodable { let message: String? }
    }

    /// owner: An organization to create it in; the account's own without one.
    static func createRepository(name: String, isPrivate: Bool, owner: String? = nil, token: String, session: URLSession) async throws -> String {
        let url = owner.flatMap { owner in
            owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "https://api.github.com/orgs/\($0)/repos") }
        } ?? repositoriesURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "private": isPrivate, "auto_init": false])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 201 {
            return try JSONDecoder().decode(CreatedRepository.self, from: data).cloneURL
        }
        let error = try? JSONDecoder().decode(APIError.self, from: data)
        if status == 422 {
            throw GitHubSignInError.repository(error?.errors?.first?.message ?? "A repository named \(name) already exists.")
        }
        if status == 401 { throw GitHubSignInError.notSignedIn }
        if status == 403 || status == 404, let owner {
            // An organization that hasn't approved the app, or one you can't create in.
            throw GitHubSignInError.repository(error?.message ?? "You can't create repositories in \(owner).")
        }
        throw GitHubSignInError.repository(error?.message ?? "GitHub couldn't create the repository (\(status)).")
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum GitHubSignInError: LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case denied
    case stateMismatch
    case notSignedIn
    case repository(String)
    case oauth(code: String, description: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Signing in with GitHub isn't set up in this app."
        case .cancelled: "GitHub sign-in was cancelled."
        case .denied: "GitHub sign-in was denied."
        case .stateMismatch: "GitHub's reply didn't match this sign-in. Try again."
        case .notSignedIn: "Sign in to GitHub first."
        case let .repository(message): message
        case let .oauth(code, description): description.isEmpty ? "GitHub sign-in failed: \(code)" : description
        }
    }
}
