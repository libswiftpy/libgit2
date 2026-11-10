//
//  LibGit2.swift
//  SwiftPyGit
//

import Foundation
@preconcurrency import libgit2
import SwiftPy

/// libgit2's global state, set up once.
let libgit2Initialized: Bool = {
    git_libgit2_init() >= 0
}()

/// What a failed libgit2 call raises, as pygit2 does: a missing object or
/// reference is a `KeyError`, a malformed name a `ValueError`, the rest a
/// `GitError`.
func gitError(_ status: Int32, notFound: String? = nil) -> PythonError {
    let message = git_error_last().flatMap { error in
        error.pointee.message.map { String(cString: $0) }
    } ?? "libgit2 error \(status)"

    switch git_error_code(rawValue: status) {
    case GIT_ENOTFOUND:
        return .KeyError(notFound ?? message)
    case GIT_EINVALIDSPEC, GIT_EAMBIGUOUS:
        return .ValueError(message)
    default:
        if message.localizedCaseInsensitiveContains("unsupported URL protocol") {
            return sshUnavailable
        }
        return PythonError(type: "pygit2.GitError", value: message)
    }
}

/// Throws for a negative status.
func check(_ status: Int32, notFound: String? = nil) throws(PythonError) {
    if status < 0 { throw gitError(status, notFound: notFound) }
}

let sshUnavailable = PythonError(
    type: "pygit2.GitError",
    value: "SSH isn't available in PyPrompt; use an HTTPS URL with a token"
)

/// SSH would start the system `ssh`, which an app can't do on iOS and a
/// sandboxed Mac app can't give keys to; refused before libgit2 tries.
func refuseSSH(_ url: String) throws(PythonError) {
    let lowered = url.lowercased()
    if lowered.hasPrefix("ssh://") || lowered.hasPrefix("git+ssh://") || lowered.hasPrefix("ssh+git://") {
        throw sshUnavailable
    }
    // scp-like `user@host:path`, which has no scheme.
    if !lowered.contains("://"), url.range(of: #"^[^/:@]+@[^/:]+:"#, options: .regularExpression) != nil {
        throw sshUnavailable
    }
}

// MARK: - Object ids

func hex(_ oid: UnsafePointer<git_oid>) -> String {
    var buffer = [CChar](repeating: 0, count: Int(GIT_OID_MAX_HEXSIZE) + 1)
    git_oid_tostr(&buffer, buffer.count, oid)
    return String(cString: buffer)
}

func hex(_ oid: git_oid) -> String {
    withUnsafePointer(to: oid) { hex($0) }
}

/// Whether `text` is a whole SHA-1 or SHA-256 id rather than a name.
func isFullId(_ text: String) -> Bool {
    (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
}

func oid(_ hex: String) throws(PythonError) -> git_oid {
    var oid = git_oid()
    let status = git_oid_fromstr(&oid, hex)
    guard status == 0 else { throw .ValueError("'\(hex)' is not a valid object id") }
    return oid
}

// MARK: - Strings

/// Runs `body` with `strings` as a `git_strarray`, valid only inside it.
func withStrarray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<git_strarray>) throws(PythonError) -> T) throws(PythonError) -> T {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var array = pointers
    return try array.withUnsafeMutableBufferPointer { (buffer) throws(PythonError) -> T in
        var strarray = git_strarray(strings: buffer.baseAddress, count: buffer.count)
        return try body(&strarray)
    }
}

func strings(of array: git_strarray) -> [String] {
    (0..<array.count).compactMap { index in
        array.strings[index].map { String(cString: $0) }
    }
}

func optionalString(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

// MARK: - JSON

/// Records cross to Python as JSON, which the `pygit2` module turns into objects.
func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
        return "null"
    }
    return String(decoding: data, as: UTF8.self)
}

func signatureRecord(_ signature: UnsafePointer<git_signature>?) -> Any {
    guard let signature else { return NSNull() }
    return [
        "name": optionalString(signature.pointee.name) ?? "",
        "email": optionalString(signature.pointee.email) ?? "",
        "time": Int(signature.pointee.when.time),
        "offset": Int(signature.pointee.when.offset),
    ] as [String: Any]
}
