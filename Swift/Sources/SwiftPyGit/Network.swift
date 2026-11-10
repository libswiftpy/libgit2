//
//  Network.swift
//  SwiftPyGit
//

import Foundation
@preconcurrency import libgit2
import SwiftPy

/// Clone, fetch and push: libgit2 works on a thread of its own while the
/// calling Python thread waits, so main stays free. libgit2's callbacks reach
/// the `pygit2.RemoteCallbacks` on main, which holds the GIL.
@MainActor
enum Network {
    static func clone(url: String, path: String, bare: Bool, checkoutBranch: String?, callbacks: PyObject?) async throws(PythonError) -> Repo {
        try refuseSSH(url)
        let localPath = Path(path).url.path
        let context = CallbackContext(callbacks: callbacks)
        let (status, pointer) = await Task.detached {
            var options = git_clone_options()
            git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
            options.bare = bare ? 1 : 0
            context.install(in: &options.fetch_opts.callbacks)
            var out: OpaquePointer?
            let status = withOptionalCString(checkoutBranch) { branch in
                options.checkout_branch = branch
                return git_clone(&out, url, localPath, &options)
            }
            return (status, SendablePointer(out))
        }.value
        try context.finish(status)
        guard let repository = pointer.value else { throw gitError(status) }
        return Repo(pointer: repository)
    }

    /// Fetches and returns the transfer's statistics as JSON.
    static func fetch(repo: Repo, remote name: String, refspecs: [String]?, callbacks: PyObject?) async throws(PythonError) -> String {
        let remote = try lookup(remote: name, in: repo)
        let context = CallbackContext(callbacks: callbacks)
        let (status, stats) = await Task.detached {
            var options = git_fetch_options()
            git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
            context.install(in: &options.callbacks)
            let status: Int32
            if let refspecs {
                status = (try? withStrarray(refspecs) { array in git_remote_fetch(remote.value, array, &options, nil) }) ?? -1
            } else {
                status = git_remote_fetch(remote.value, nil, &options, nil)
            }
            let stats = git_remote_stats(remote.value).map { stats in
                [
                    "total_objects": Int(stats.pointee.total_objects),
                    "indexed_objects": Int(stats.pointee.indexed_objects),
                    "received_objects": Int(stats.pointee.received_objects),
                    "local_objects": Int(stats.pointee.local_objects),
                    "total_deltas": Int(stats.pointee.total_deltas),
                    "indexed_deltas": Int(stats.pointee.indexed_deltas),
                    "received_bytes": Int(stats.pointee.received_bytes),
                ]
            } ?? [:]
            git_remote_free(remote.value)
            return (status, stats)
        }.value
        try context.finish(status)
        return json(stats)
    }

    static func push(repo: Repo, remote name: String, specs: [String], callbacks: PyObject?) async throws(PythonError) {
        let remote = try lookup(remote: name, in: repo)
        let context = CallbackContext(callbacks: callbacks)
        let status = await Task.detached {
            var options = git_push_options()
            git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
            context.install(in: &options.callbacks)
            let status = (try? withStrarray(specs) { array in git_remote_push(remote.value, array, &options) }) ?? -1
            git_remote_free(remote.value)
            return status
        }.value
        try context.finish(status)
    }

    private static func lookup(remote name: String, in repo: Repo) throws(PythonError) -> SendablePointer {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repo.handle, name), notFound: name)
        if let url = optionalString(git_remote_url(remote)) {
            do throws(PythonError) {
                try refuseSSH(url)
            } catch {
                git_remote_free(remote)
                throw error
            }
        }
        return SendablePointer(remote)
    }
}

/// A libgit2 handle carried to the thread that uses it; only that thread
/// touches it meanwhile.
struct SendablePointer: @unchecked Sendable {
    let value: OpaquePointer?
    init(_ value: OpaquePointer?) { self.value = value }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// What libgit2's callbacks need: the Python callbacks, reached on main, and
/// the first error one raised, rethrown once libgit2 returns.
final class CallbackContext: @unchecked Sendable {
    /// Touched only on main.
    private let callbacks: PyObject?
    private var error: PythonError?
    private var credentialAttempts = 0

    init(callbacks: PyObject?) {
        self.callbacks = callbacks
    }

    func install(in remoteCallbacks: inout git_remote_callbacks) {
        remoteCallbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        remoteCallbacks.credentials = credentialsCallback
        remoteCallbacks.push_update_reference = pushUpdateReferenceCallback
        if callbacks != nil {
            remoteCallbacks.transfer_progress = transferProgressCallback
        }
    }

    /// Rethrows what a callback raised, else libgit2's own error.
    func finish(_ status: Int32) throws(PythonError) {
        if let error { throw error }
        try check(status)
    }

    fileprivate func fail(_ error: PythonError) -> Int32 {
        if self.error == nil { self.error = error }
        return GIT_EUSER.rawValue
    }

    /// Runs `body` on main, where Python may be called.
    fileprivate func onMain<T>(_ body: @MainActor (PyObject) throws(PythonError) -> T) -> Result<T, PythonError>? {
        guard let callbacks else { return nil }
        let object = callbacks
        nonisolated(unsafe) var result: Result<T, PythonError>?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                do throws(PythonError) {
                    result = .success(try body(object))
                } catch {
                    result = .failure(error)
                }
            }
        }
        return result
    }

    fileprivate func credential(
        _ out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
        url: String,
        username: String?,
        allowed: UInt32
    ) -> Int32 {
        credentialAttempts += 1
        // libgit2 asks again after a refusal; a wrong token would loop forever.
        guard credentialAttempts <= 3 else {
            return fail(PythonError(type: "pygit2.GitError", value: "authentication failed for '\(url)'"))
        }
        // [type, username, password]: what the Python side chose, or None.
        let answer = onMain { (callbacks) throws(PythonError) -> (Int, String, String?)? in
            guard let fields: [PyObject] = try callbacks._git_credentials?(url, username, Int(allowed)),
                  fields.count >= 2,
                  let type = Int(fields[0]),
                  let user = String(fields[1]) else { return nil }
            let password = fields.count > 2 ? Keychain.value(fields[2]) : nil
            return (type, user, password)
        }
        switch answer {
        case .none, .success(.none):
            return GIT_PASSTHROUGH.rawValue
        case .failure(let error):
            return fail(error)
        case .success(.some(let (type, user, password))):
            switch UInt32(type) {
            case GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue:
                return git_credential_userpass_plaintext_new(out, user, password ?? "")
            case GIT_CREDENTIAL_USERNAME.rawValue:
                return git_credential_username_new(out, user)
            default:
                return fail(sshUnavailable)
            }
        }
    }

    fileprivate func transferProgress(_ stats: git_indexer_progress) -> Int32 {
        let outcome = onMain { (callbacks) throws(PythonError) in
            try callbacks._git_transfer_progress?(
                Int(stats.total_objects), Int(stats.indexed_objects), Int(stats.received_objects),
                Int(stats.local_objects), Int(stats.total_deltas), Int(stats.indexed_deltas),
                Int(stats.received_bytes)
            )
        }
        if case .failure(let error) = outcome { return fail(error) }
        return 0
    }

    fileprivate func pushUpdateReference(_ refname: String, message: String?) -> Int32 {
        let outcome = onMain { (callbacks) throws(PythonError) in
            try callbacks._git_push_update_reference?(refname, message)
        }
        switch outcome {
        case .failure(let error):
            return fail(error)
        case .none where message != nil:
            // No callbacks to tell: a rejected reference fails the push.
            return fail(PythonError(type: "pygit2.GitError", value: "\(refname) push failed: \(message!)"))
        default:
            return 0
        }
    }
}

private func context(_ payload: UnsafeMutableRawPointer?) -> CallbackContext? {
    payload.map { Unmanaged<CallbackContext>.fromOpaque($0).takeUnretainedValue() }
}

private let credentialsCallback: git_credential_acquire_cb = { out, url, username, allowed, payload in
    guard let context = context(payload) else { return GIT_PASSTHROUGH.rawValue }
    return context.credential(out, url: optionalString(url) ?? "", username: optionalString(username), allowed: allowed)
}

private let transferProgressCallback: git_indexer_progress_cb = { stats, payload in
    guard let stats, let context = context(payload) else { return 0 }
    return context.transferProgress(stats.pointee)
}

private let pushUpdateReferenceCallback: git_push_update_reference_cb = { refname, status, payload in
    guard let context = context(payload) else { return 0 }
    return context.pushUpdateReference(optionalString(refname) ?? "", message: optionalString(status))
}
