//
//  NetworkStreamTests.swift
//  SwiftPyGit
//

import Foundation
import Testing
import SwiftPy
import SwiftPyGit

/// The App Clip's `NWConnection` streams, which stay registered for the
/// process. Needs the network: github.com and badssl.com.
@Suite(.serialized) @MainActor
struct NetworkStreamTests {
    let directory: String

    init() throws {
        SwiftPyGit.initialize(usesNetworkFramework: true)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "pygit2-network-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func run(_ code: String) async -> String? {
        await Interpreter.run("import pygit2, os, traceback\nroot = '\(directory)'\n_result = None\ntry:\n" + code.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\nexcept BaseException:\n    _result = traceback.format_exc()")
        let result: String? = Interpreter.evaluate("_result if isinstance(_result, str) and _result.startswith('Traceback') else repr(_result)")
        return result
    }

    @Test func clonesAPublicRepository() async {
        let result = await run("""
        repo = pygit2.clone_repository("https://github.com/octocat/Hello-World.git", os.path.join(root, "hello"), depth=1)
        _result = (repo.head.shorthand, os.path.exists(os.path.join(repo.workdir, "README")))
        """)
        #expect(result == "('master', True)")
    }

    @Test func rejectsABadCertificate() async {
        let result = await run("""
        try:
            pygit2.clone_repository("https://expired.badssl.com/repo.git", os.path.join(root, "bad"))
            _result = "cloned"
        except pygit2.GitError as error:
            _result = str(error)
        """)
        #expect(result?.hasPrefix("'failed to connect to expired.badssl.com") == true, "\(result ?? "")")
    }
}
