//
//  GitHubAccount.swift
//  SwiftPyGit
//

import AuthenticationServices
import Foundation
import SwiftPy
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A GitHub account signed in through the browser; its token is the keychain
/// secret `GITHUB_TOKEN`, which pygit2 and requests take as they take any.
@MainActor
public final class GitHubAccount {
    public static let shared = GitHubAccount()

    /// The OAuth App's client ID and secret; the host sets them.
    public var clientID: String?
    public var clientSecret: String?

    /// The callback, `<scheme>://oauth/github`, as the OAuth App's callback URL names it.
    public nonisolated static let callbackHost = "oauth"
    public nonisolated static let callbackPath = "/github"

    static let tokenName = "GITHUB_TOKEN"
    private static let loginKey = "GitHubLogin"

    var session = URLSession.shared

    /// The app's own URL scheme, such as `pyprompt`, or one of its own without one.
    static let callbackScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return schemes?.first ?? "swiftpy-github"
    }()

    static var redirect: URL { URL(string: "\(callbackScheme)://\(callbackHost)\(callbackPath)")! }

    /// The signed-in login, while its token is still in the keychain.
    public var login: String? {
        guard Keychain.names.contains(Self.tokenName) else { return nil }
        return UserDefaults.standard.string(forKey: Self.loginKey)
    }

    /// Signs in in the browser sheet and saves the token; returns the login.
    public func signIn() async throws -> String {
        guard let clientID, !clientID.isEmpty, let clientSecret, !clientSecret.isEmpty else {
            throw GitHubSignInError.notConfigured
        }
        let attempt = GitHubAuthorization.Attempt()
        let url = GitHubAuthorization.authorizeURL(clientID: clientID, redirect: Self.redirect, attempt: attempt)
        let callback = try await SignInSheet.run(url, scheme: Self.callbackScheme)
        let code = try GitHubAuthorization.code(from: callback, attempt: attempt)
        let token = try await GitHubAuthorization.exchange(
            code: code, attempt: attempt, clientID: clientID, clientSecret: clientSecret,
            redirect: Self.redirect, session: session
        )
        let login = try await GitHubAuthorization.login(token: token, session: session)
        try Keychain.set(token, for: Self.tokenName)
        UserDefaults.standard.set(login, forKey: Self.loginKey)
        return login
    }

    /// Creates an empty repository on the signed-in account, or in `owner`, an
    /// organization; returns its HTTPS clone URL.
    public func createRepository(name: String, isPrivate: Bool, owner: String? = nil) async throws -> String {
        guard let token = Secret(name: Self.tokenName).value else { throw GitHubSignInError.notSignedIn }
        return try await GitHubAuthorization.createRepository(name: name, isPrivate: isPrivate, owner: owner, token: token, session: session)
    }

    /// The signed-in account's organizations.
    public func organizations() async throws -> [String] {
        guard let token = Secret(name: Self.tokenName).value else { throw GitHubSignInError.notSignedIn }
        return try await GitHubAuthorization.organizations(token: token, session: session)
    }

    public func signOut() throws(PythonError) {
        try Keychain.delete(Self.tokenName)
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
    }
}

/// GitHub's authorize page in the system browser sheet, until it redirects
/// to the app's scheme.
@MainActor
private final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    // Kept while the sheet shows; nothing else holds it.
    private var session: ASWebAuthenticationSession?

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    static func run(_ url: URL, scheme: String) async throws -> URL {
        // No window to show the sheet over, as when a shortcut runs it.
        guard let anchor = keyWindow() else { throw GitHubSignInError.cancelled }
        let presenter = SignInSheet(anchor: anchor)
        defer { withExtendedLifetime(presenter) {} }
        return try await withCheckedThrowingContinuation { continuation in
            // Called on AuthenticationServices' own queue, not main.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GitHubSignInError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GitHubSignInError.cancelled)
                }
            }
            session.presentationContextProvider = presenter
            presenter.session = session
            if !session.start() {
                continuation.resume(throwing: GitHubSignInError.cancelled)
            }
        }
    }

    private static func keyWindow() -> ASPresentationAnchor? {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        #endif
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
