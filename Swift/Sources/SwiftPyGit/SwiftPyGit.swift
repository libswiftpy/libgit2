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
    public static func initialize() {
        precondition(libgit2Initialized)

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

            module.def("clone(url: str, path: str, bare: bool, checkout_branch: str | None, callbacks: object) -> Repo") { argc, argv in
                PyBind.blocking(argc, argv) { (url: String, path: String, bare: Bool, branch: String?, callbacks: PyObject?) in
                    try await Network.clone(url: url, path: path, bare: bare, checkoutBranch: branch, callbacks: callbacks)
                }
            }

            module.def("fetch(repo: Repo, remote: str, refspecs: list[str] | None, callbacks: object) -> str") { argc, argv in
                PyBind.blocking(argc, argv) { (repo: Repo, remote: String, refspecs: [String]?, callbacks: PyObject?) in
                    try await Network.fetch(repo: repo, remote: remote, refspecs: refspecs, callbacks: callbacks)
                }
            }

            module.def("push(repo: Repo, remote: str, specs: list[str], callbacks: object) -> None") { argc, argv in
                PyBind.blocking(argc, argv) { (repo: Repo, remote: String, specs: [String], callbacks: PyObject?) in
                    try await Network.push(repo: repo, remote: remote, specs: specs, callbacks: callbacks)
                }
            }
        }

        PyBind.module("pygit2", in: .module)
    }
}
