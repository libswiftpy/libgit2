//
//  PyGit2Tests.swift
//  SwiftPyGit
//

import Foundation
import Testing
import SwiftPy
import SwiftPyGit

@Suite(.serialized) @MainActor
struct PyGit2Tests {
    let directory: String

    init() throws {
        SwiftPyGit.initialize()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "pygit2-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// Runs `code` with `root` bound to the test's folder and returns
    /// `repr(_result)`, or the traceback when it raised.
    private func run(_ code: String) async -> String? {
        await Interpreter.run("import pygit2, os, traceback\nroot = \(repr(directory))\n_result = None\ntry:\n" + code.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\nexcept BaseException:\n    _result = traceback.format_exc()")
        let result: String? = Interpreter.evaluate("_result if isinstance(_result, str) and _result.startswith('Traceback') else repr(_result)")
        return result
    }

    private func repr(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A repository with two commits on main, as `repo`.
    private let twoCommits = """
    repo = pygit2.init_repository(os.path.join(root, "work"), initial_head="main")
    me = pygit2.Signature("Ada", "ada@example.com", 1_700_000_000, 60)
    def commit(path, text, message):
        with open(os.path.join(repo.workdir, path), "w") as file:
            file.write(text)
        repo.index.add(path)
        repo.index.write()
        tree = repo.index.write_tree()
        parents = [] if repo.head_is_unborn else [repo.head.target]
        return repo.create_commit("HEAD", me, me, message, tree, parents)
    first = commit("hello.txt", "hello\\n", "First")
    second = commit("hello.txt", "hello, world\\n", "Second")
    """

    @Test func commitsReadBackWithTheirHistoryAndContents() async {
        let result = await run(twoCommits + "\n" + """
        head = repo[repo.head.target]
        log = [c.message for c in repo.walk(repo.head.target, pygit2.enums.SortMode.TIME)]
        blob = head.tree["hello.txt"]
        _result = (
            repo.head.shorthand, log, head.parents[0].id == first,
            head.author.name, head.author.offset, blob.data, blob.name, isinstance(blob, pygit2.Blob),
            head.tree_id == head.tree.id, repo.revparse_single("HEAD~1").id == first,
        )
        """)
        #expect(result == "('main', ['Second', 'First'], True, 'Ada', 60, b'hello, world\\n', 'hello.txt', True, True, True)")
    }

    @Test func statusBranchesCheckoutAndReset() async {
        let result = await run(twoCommits + "\n" + """
        with open(os.path.join(repo.workdir, "new.txt"), "w") as file:
            file.write("x")
        status = repo.status()
        branch = repo.branches.local.create("feature", repo[first])
        repo.checkout(branch)
        on_feature = (repo.head.shorthand, open(os.path.join(repo.workdir, "hello.txt")).read())
        repo.checkout("refs/heads/main")
        repo.reset(first, pygit2.enums.ResetMode.HARD)
        _result = (
            status["new.txt"] == pygit2.enums.FileStatus.WT_NEW, sorted(repo.branches.local),
            on_feature, repo[repo.head.target].message, "feature" in repo.branches,
            branch.branch_name, repo.references["refs/heads/feature"].target == first,
        )
        """)
        #expect(result == "(True, ['feature', 'main'], ('feature', 'hello\\n'), 'First', True, 'feature', True)")
    }

    @Test func missingThingsRaisePygit2sErrors() async {
        let result = await run(twoCommits + "\n" + """
        errors = []
        for attempt in (
            lambda: repo.references["refs/heads/nope"],
            lambda: repo["0" * 40],
            lambda: repo.config["no.such-key"],
            lambda: pygit2.Repository(os.path.join(root, "missing")),
            lambda: repo.remotes["origin"],
        ):
            try:
                attempt()
                errors.append(None)
            except Exception as error:
                errors.append(type(error).__name__)
        _result = errors
        """)
        #expect(result == "['KeyError', 'KeyError', 'KeyError', 'GitError', 'KeyError']")
    }

    @Test func clonesFetchesAndPushesOverFileURLs() async {
        let result = await run(twoCommits + "\n" + """
        bare = pygit2.clone_repository("file://" + repo.path, os.path.join(root, "bare.git"), bare=True)
        copy = pygit2.clone_repository("file://" + bare.path, os.path.join(root, "copy"))
        third = commit("other.txt", "more", "Third")
        repo.remotes.create("origin", "file://" + bare.path)
        repo.remotes["origin"].push(["refs/heads/main"])
        progress = []
        class Callbacks(pygit2.RemoteCallbacks):
            def transfer_progress(self, stats):
                progress.append(stats.received_objects)
        stats = copy.remotes["origin"].fetch(callbacks=Callbacks())
        _result = (
            bare.is_bare, copy[copy.head.target].message, copy.remotes["origin"].url.startswith("file://"),
            copy.references["refs/remotes/origin/main"].target == third, stats.received_objects > 0,
            bool(progress),
        )
        """)
        #expect(result == "(True, 'Second', True, True, True, True)")
    }

    @Test func sshIsRefusedWithAHint() async {
        let result = await run("""
        messages = []
        for url in ("git@github.com:owner/project.git", "ssh://git@github.com/owner/project.git"):
            try:
                pygit2.clone_repository(url, os.path.join(root, "ssh"))
            except pygit2.GitError as error:
                messages.append("HTTPS" in str(error))
        _result = messages
        """)
        #expect(result == "[True, True]")
    }

    @Test func credentialsFollowPygit2sCallbacks() async {
        let result = await run("""
        allowed = pygit2.enums.CredentialType.USERPASS_PLAINTEXT
        given = pygit2.RemoteCallbacks(credentials=pygit2.UserPass("me", "token"))
        class Asked(pygit2.RemoteCallbacks):
            def credentials(self, url, username_from_url, allowed_types):
                return pygit2.UserPass(username_from_url or "x", url)
        _result = (
            given._git_credentials("https://host/repo", None, int(allowed)),
            Asked()._git_credentials("https://host/repo", "git", int(allowed)),
            pygit2.RemoteCallbacks()._git_credentials("https://host/repo", None, int(allowed)),
        )
        """)
        #expect(result == "([1, 'me', 'token'], [1, 'git', 'https://host/repo'], None)")
    }

    /// pygit2's own recipes, as its documentation writes them.
    @Test func pygit2RecipesRunUnchanged() async {
        let result = await run(twoCommits + "\n" + """
        from pygit2.enums import SortMode
        from pygit2 import GIT_SORT_TOPOLOGICAL
        last = repo[repo.head.target]
        messages = [commit.message for commit in repo.walk(last.id, SortMode.TOPOLOGICAL | SortMode.REVERSE)]
        repo.config["user.name"] = "Grace"
        repo.config["user.email"] = "grace@example.com"
        signature = repo.default_signature
        _result = (messages, signature.name, GIT_SORT_TOPOLOGICAL, pygit2.GIT_OBJECT_COMMIT)
        """)
        #expect(result == "(['First', 'Second'], 'Grace', 1, 1)")
    }
}
