//
//  SwiftPyGit.swift
//  SwiftPyGit
//
//

import Foundation
@preconcurrency import libgit2
import SwiftPy

/// `pygit2`, with pygit2's names, on libgit2: the Python module in
/// `pygit2.py` over the native `_pygit2`.
@MainActor
public enum SwiftPyGit {
    /// signInWithGitHub: Whether `github.sign_in()` is offered; it needs
    /// ``GitHubAccount/clientID`` and ``GitHubAccount/clientSecret``. A token already saved is used either way.
    /// usesNetworkFramework: Connects through `NWConnection` instead of POSIX sockets, which an App Clip can't use.
    public static func initialize(signInWithGitHub: Bool = false, usesNetworkFramework: Bool = false) {
        precondition(libgit2Initialized)
        if usesNetworkFramework { NetworkStream.register() }

        PyBind.module("_pygit2", docs: "libgit2 for the pygit2 module; use pygit2 instead.") { module in
            module.class(Repo.self)

            module.def("open_repository(path: str) -> Repo") { argc, argv in
                PyBind.function(argc, argv) { (path: String) throws(PythonError) -> Repo in
                    var repository: OpaquePointer?
                    // Searches upwards, as pygit2 does, so a folder inside the work tree opens it.
                    try check(git_repository_open_ext(&repository, Path(path).url.path, 0, nil), notFound: "no repository at '\(path)'")
                    return Repo(pointer: repository!)
                }
            }

            module.def("init_repository(path: str, bare: bool) -> Repo") { argc, argv in
                PyBind.function(argc, argv) { (path: String, bare: Bool) throws(PythonError) -> Repo in
                    var repository: OpaquePointer?
                    try check(git_repository_init(&repository, Path(path).url.path, bare ? 1 : 0))
                    return Repo(pointer: repository!)
                }
            }

            module.def("clone(url: str, path: str, bare: bool, checkout_branch: str | None, depth: int, callbacks: object) -> Repo") { argc, argv in
                PyBind.blocking(argc, argv) { (url: String, path: String, bare: Bool, branch: String?, depth: Int, callbacks: PyObject?) in
                    try await Network.clone(url: url, path: path, bare: bare, checkoutBranch: branch, depth: depth, callbacks: callbacks)
                }
            }

            module.def("fetch(repo: Repo, remote: str, refspecs: list[str] | None, prune: int, depth: int, callbacks: object) -> str") { argc, argv in
                PyBind.blocking(argc, argv) { (repo: Repo, remote: String, refspecs: [String]?, prune: Int, depth: Int, callbacks: PyObject?) in
                    try await Network.fetch(repo: repo, remote: remote, refspecs: refspecs, prune: prune, depth: depth, callbacks: callbacks)
                }
            }

            module.def("push(repo: Repo, remote: str, specs: list[str], callbacks: object) -> None") { argc, argv in
                PyBind.blocking(argc, argv) { (repo: Repo, remote: String, specs: [String], callbacks: PyObject?) in
                    try await Network.push(repo: repo, remote: remote, specs: specs, callbacks: callbacks)
                }
            }
        }

        PyBind.module("pygit2", in: .module)
        bindGitHub(signsIn: signInWithGitHub)
    }

    private static func bindGitHub(signsIn: Bool) {
        PyBind.module("_github", docs: "GitHub sign-in for the github module; use github instead.") { module in
            if signsIn {
                module.def(
                    "sign_in() -> str",
                    docstring: """
                    Signs in to GitHub in the browser and returns the account's login.

                    It asks for access to your repositories, public and private. The \
                    token is saved in the keychain as GITHUB_TOKEN.
                    """
                ) { argc, argv in
                    PyBind.blocking(argc, argv) {
                        try await GitHubAccount.shared.signIn()
                    }
                }
            }
            module.def(
                "create_repository(name: str, private: bool, owner: str | None) -> str",
                docstring: "Creates an empty repository on the signed-in account, or in the organization owner; returns its HTTPS clone URL."
            ) { argc, argv in
                PyBind.blocking(argc, argv) { (name: String, isPrivate: Bool, owner: String?) in
                    try await GitHubAccount.shared.createRepository(name: name, isPrivate: isPrivate, owner: owner)
                }
            }
            module.def("organizations() -> list[str]", docstring: "The signed-in account's organizations.") { argc, argv in
                PyBind.blocking(argc, argv) {
                    try await GitHubAccount.shared.organizations()
                }
            }
            module.def("sign_out() -> None", docstring: "Signs out of GitHub, deleting the GITHUB_TOKEN secret.") { argc, argv in
                PyBind.function(argc, argv) { () throws(PythonError) in
                    try GitHubAccount.shared.signOut()
                }
            }
            module.def("account() -> str | None", docstring: "The signed-in GitHub login, or None when signed out.") { argc, argv in
                PyBind.function(argc, argv) {
                    GitHubAccount.shared.login
                }
            }
        }
        PyBind.module("github", in: .module)
    }
}
