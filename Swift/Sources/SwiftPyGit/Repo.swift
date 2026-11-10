//
//  Repo.swift
//  SwiftPyGit
//

import Foundation
@preconcurrency import libgit2
import SwiftPy

/// An open repository: the native side of `pygit2.Repository`, which turns
/// its JSON records into pygit2's objects.
@Scriptable
@MainActor
final class Repo {
    nonisolated(unsafe) private let pointer: OpaquePointer
    /// The repository's index, opened once so unwritten changes stay in it.
    nonisolated(unsafe) private var indexPointer: OpaquePointer?

    internal init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        if let indexPointer { git_index_free(indexPointer) }
        git_repository_free(pointer)
    }

    internal nonisolated var handle: OpaquePointer { pointer }

    // MARK: State

    /// path, workdir, is_bare, is_empty, head_is_unborn and head_is_detached.
    func info() -> String {
        json([
            "path": optionalString(git_repository_path(pointer)) ?? "",
            "workdir": optionalString(git_repository_workdir(pointer)) as Any? ?? NSNull(),
            "is_bare": git_repository_is_bare(pointer) == 1,
            "is_empty": git_repository_is_empty(pointer) == 1,
            "head_is_unborn": git_repository_head_unborn(pointer) == 1,
            "head_is_detached": git_repository_head_detached(pointer) == 1,
        ] as [String: Any])
    }

    // MARK: Objects

    /// The object's id, type and its fields: a commit's message and parents, a
    /// tree's entries, a blob's size, a tag's target.
    func object(_ id: String) throws(PythonError) -> String {
        var target = try oid(id)
        var object: OpaquePointer?
        try check(git_object_lookup(&object, pointer, &target, GIT_OBJECT_ANY), notFound: id)
        defer { git_object_free(object) }
        return json(record(of: object!))
    }

    /// The id `spec` names, such as "HEAD~2" or a short id.
    func revparse(_ spec: String) throws(PythonError) -> String {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, pointer, spec), notFound: spec)
        defer { git_object_free(object) }
        return hex(git_object_id(object)!)
    }

    /// The object `id` peels to, of `type` (pygit2's ObjectType value).
    func peel(_ id: String, _ type: Int) throws(PythonError) -> String {
        var target = try oid(id)
        var object: OpaquePointer?
        try check(git_object_lookup(&object, pointer, &target, GIT_OBJECT_ANY), notFound: id)
        defer { git_object_free(object) }
        var peeled: OpaquePointer?
        try check(git_object_peel(&peeled, object, git_object_t(rawValue: Int32(type))))
        defer { git_object_free(peeled) }
        return hex(git_object_id(peeled)!)
    }

    /// A blob's bytes.
    func blobData(_ id: String) throws(PythonError) -> Data {
        var target = try oid(id)
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &target), notFound: id)
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let bytes = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: bytes, count: size)
    }

    /// Writes `data` as a blob and returns its id.
    func createBlob(_ data: Data) throws(PythonError) -> String {
        var id = git_oid()
        let status = data.withUnsafeBytes { bytes in
            git_blob_create_from_buffer(&id, pointer, bytes.baseAddress, bytes.count)
        }
        try check(status)
        return hex(id)
    }

    /// The entry at a slash-separated `path` under the tree `id`, as a record
    /// of name, id, type and filemode.
    func treeEntry(_ id: String, _ path: String) throws(PythonError) -> String {
        var target = try oid(id)
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &target), notFound: id)
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        try check(git_tree_entry_bypath(&entry, tree, path), notFound: path)
        defer { git_tree_entry_free(entry) }
        return json(entryRecord(entry!))
    }

    private func record(of object: OpaquePointer) -> [String: Any] {
        let type = git_object_type(object)
        var record: [String: Any] = [
            "id": hex(git_object_id(object)!),
            "type": Int(type.rawValue),
        ]
        switch type {
        case GIT_OBJECT_COMMIT:
            let parents = (0..<git_commit_parentcount(object)).map { hex(git_commit_parent_id(object, $0)!) }
            record["message"] = optionalString(git_commit_message(object)) ?? ""
            record["author"] = signatureRecord(git_commit_author(object))
            record["committer"] = signatureRecord(git_commit_committer(object))
            record["parents"] = parents
            record["tree"] = hex(git_commit_tree_id(object)!)
            record["commit_time"] = Int(git_commit_time(object))
            record["commit_time_offset"] = Int(git_commit_time_offset(object))
        case GIT_OBJECT_TREE:
            record["entries"] = (0..<git_tree_entrycount(object)).compactMap { index in
                git_tree_entry_byindex(object, index).map(entryRecord)
            }
        case GIT_OBJECT_BLOB:
            record["size"] = Int(git_blob_rawsize(object))
            record["is_binary"] = git_blob_is_binary(object) == 1
        case GIT_OBJECT_TAG:
            record["name"] = optionalString(git_tag_name(object)) ?? ""
            record["message"] = optionalString(git_tag_message(object)) ?? ""
            record["target"] = hex(git_tag_target_id(object)!)
            record["target_type"] = Int(git_tag_target_type(object).rawValue)
            record["tagger"] = signatureRecord(git_tag_tagger(object))
        default:
            break
        }
        return record
    }

    private func entryRecord(_ entry: OpaquePointer) -> [String: Any] {
        [
            "name": optionalString(git_tree_entry_name(entry)) ?? "",
            "id": hex(git_tree_entry_id(entry)!),
            "type": Int(git_tree_entry_type(entry).rawValue),
            "filemode": Int(git_tree_entry_filemode(entry).rawValue),
        ]
    }

    // MARK: References

    func referenceNames() throws(PythonError) -> [String] {
        var array = git_strarray()
        try check(git_reference_list(&array, pointer))
        defer { git_strarray_dispose(&array) }
        return strings(of: array)
    }

    /// name, shorthand, type (1 direct, 2 symbolic) and target: an id, or the
    /// name a symbolic reference points to. `None` for HEAD on an unborn branch
    /// is not raised: its target is still the branch it names.
    func reference(_ name: String) throws(PythonError) -> String {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name), notFound: name)
        defer { git_reference_free(reference) }
        return json(referenceRecord(reference!))
    }

    /// The name of the direct reference `name` ends at, following symbolic ones.
    func resolveReference(_ name: String) throws(PythonError) -> String {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name), notFound: name)
        defer { git_reference_free(reference) }
        var resolved: OpaquePointer?
        try check(git_reference_resolve(&resolved, reference), notFound: name)
        defer { git_reference_free(resolved) }
        return json(referenceRecord(resolved!))
    }

    func createReference(_ name: String, _ target: String, _ force: Bool) throws(PythonError) -> String {
        var reference: OpaquePointer?
        if isFullId(target) {
            var id = try oid(target)
            try check(git_reference_create(&reference, pointer, name, &id, force ? 1 : 0, nil))
        } else {
            try check(git_reference_symbolic_create(&reference, pointer, name, target, force ? 1 : 0, nil))
        }
        defer { git_reference_free(reference) }
        return json(referenceRecord(reference!))
    }

    func deleteReference(_ name: String) throws(PythonError) {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name), notFound: name)
        defer { git_reference_free(reference) }
        try check(git_reference_delete(reference))
    }

    /// Points `name` at the id `target`, or at the reference `target` when
    /// `name` is symbolic.
    func setReferenceTarget(_ name: String, _ target: String) throws(PythonError) {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, name), notFound: name)
        defer { git_reference_free(reference) }
        var updated: OpaquePointer?
        if git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC {
            try check(git_reference_symbolic_set_target(&updated, reference, target, nil))
        } else {
            var id = try oid(target)
            try check(git_reference_set_target(&updated, reference, &id, nil))
        }
        git_reference_free(updated)
    }

    func setHead(_ name: String) throws(PythonError) {
        if isFullId(name) {
            var id = try oid(name)
            try check(git_repository_set_head_detached(pointer, &id))
        } else {
            try check(git_repository_set_head(pointer, name), notFound: name)
        }
    }

    private func referenceRecord(_ reference: OpaquePointer) -> [String: Any] {
        let isSymbolic = git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC
        let target: Any = isSymbolic
            ? optionalString(git_reference_symbolic_target(reference)) ?? ""
            : git_reference_target(reference).map { hex($0) } ?? NSNull()
        return [
            "name": optionalString(git_reference_name(reference)) ?? "",
            "shorthand": optionalString(git_reference_shorthand(reference)) ?? "",
            "type": isSymbolic ? 2 : 1,
            "target": target,
        ]
    }

    // MARK: Branches

    /// Full reference names of the local (1) or remote (2) branches.
    func branchNames(_ type: Int) throws(PythonError) -> [String] {
        var iterator: OpaquePointer?
        try check(git_branch_iterator_new(&iterator, pointer, git_branch_t(rawValue: UInt32(type))))
        defer { git_branch_iterator_free(iterator) }
        var names: [String] = []
        var reference: OpaquePointer?
        var branchType = git_branch_t(rawValue: 0)
        while git_branch_next(&reference, &branchType, iterator) == 0 {
            if let name = optionalString(git_reference_name(reference)) { names.append(name) }
            git_reference_free(reference)
        }
        return names
    }

    /// The branch's full reference name, from its short `name` and type.
    func branch(_ name: String, _ type: Int) throws(PythonError) -> String {
        var reference: OpaquePointer?
        try check(git_branch_lookup(&reference, pointer, name, git_branch_t(rawValue: UInt32(type))), notFound: name)
        defer { git_reference_free(reference) }
        return optionalString(git_reference_name(reference)) ?? name
    }

    func createBranch(_ name: String, _ commit: String, _ force: Bool) throws(PythonError) -> String {
        var target = try oid(commit)
        var commitObject: OpaquePointer?
        try check(git_commit_lookup(&commitObject, pointer, &target), notFound: commit)
        defer { git_commit_free(commitObject) }
        var reference: OpaquePointer?
        try check(git_branch_create(&reference, pointer, name, commitObject, force ? 1 : 0))
        defer { git_reference_free(reference) }
        return optionalString(git_reference_name(reference)) ?? name
    }

    func deleteBranch(_ referenceName: String) throws(PythonError) {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, referenceName), notFound: referenceName)
        defer { git_reference_free(reference) }
        try check(git_branch_delete(reference))
    }

    /// branch_name, is_head and the upstream's reference name, if any.
    func branchInfo(_ referenceName: String) throws(PythonError) -> String {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, referenceName), notFound: referenceName)
        defer { git_reference_free(reference) }
        var name: UnsafePointer<CChar>?
        try check(git_branch_name(&name, reference))
        var upstream: OpaquePointer?
        let upstreamName: Any
        if git_branch_upstream(&upstream, reference) == 0 {
            upstreamName = optionalString(git_reference_name(upstream)) ?? NSNull()
            git_reference_free(upstream)
        } else {
            upstreamName = NSNull()
        }
        return json([
            "branch_name": optionalString(name) ?? "",
            "is_head": git_branch_is_head(reference) == 1,
            "upstream": upstreamName,
        ] as [String: Any])
    }

    /// Sets the local branch's upstream to the remote branch `upstream`
    /// ("origin/main"), or clears it with `None`.
    func setUpstream(_ referenceName: String, _ upstream: String?) throws(PythonError) {
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, pointer, referenceName), notFound: referenceName)
        defer { git_reference_free(reference) }
        try check(git_branch_set_upstream(reference, upstream))
    }

    // MARK: History and working tree

    /// Commit ids from `id`, in pygit2's SortMode order.
    func walk(_ id: String, _ sort: Int) throws(PythonError) -> [String] {
        var start = try oid(id)
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, pointer))
        defer { git_revwalk_free(walker) }
        try check(git_revwalk_sorting(walker, UInt32(sort)))
        try check(git_revwalk_push(walker, &start), notFound: id)
        var ids: [String] = []
        var next = git_oid()
        while git_revwalk_next(&next, walker) == 0 {
            ids.append(hex(next))
        }
        return ids
    }

    /// Path to FileStatus flags, untracked files included, ignored ones left out.
    func status() throws(PythonError) -> [String: Int] {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }
        var result: [String: Int] = [:]
        for index in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, index) else { continue }
            let delta = entry.pointee.head_to_index ?? entry.pointee.index_to_workdir
            guard let delta, let path = optionalString(delta.pointee.new_file.path ?? delta.pointee.old_file.path) else { continue }
            result[path] = Int(entry.pointee.status.rawValue)
        }
        return result
    }

    func statusFile(_ path: String) throws(PythonError) -> Int {
        var flags: UInt32 = 0
        try check(git_status_file(&flags, pointer, path), notFound: path)
        return Int(flags)
    }

    /// Checks out the tree `refname` points at and moves HEAD to it; with no
    /// name, the index and working tree are made to match HEAD.
    func checkout(_ refname: String?, _ strategy: Int) throws(PythonError) {
        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(strategy)
        guard let refname else {
            try check(git_checkout_head(pointer, &options))
            return
        }
        var object: OpaquePointer?
        try check(git_revparse_single(&object, pointer, refname), notFound: refname)
        defer { git_object_free(object) }
        try check(git_checkout_tree(pointer, object, &options))
        try setHead(refname)
    }

    /// Resets HEAD to `id`, the index and working tree too for MIXED and HARD.
    func reset(_ id: String, _ mode: Int) throws(PythonError) {
        var target = try oid(id)
        var object: OpaquePointer?
        try check(git_object_lookup(&object, pointer, &target, GIT_OBJECT_ANY), notFound: id)
        defer { git_object_free(object) }
        try check(git_reset(pointer, object, git_reset_t(rawValue: UInt32(mode)), nil))
    }

    // MARK: Index

    private func index() throws(PythonError) -> OpaquePointer {
        if let indexPointer { return indexPointer }
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer))
        indexPointer = index
        return index!
    }

    /// The index's entries as [path, id, mode].
    func indexEntries() throws(PythonError) -> String {
        let index = try index()
        let entries: [[Any]] = (0..<git_index_entrycount(index)).compactMap { position in
            guard let entry = git_index_get_byindex(index, position) else { return nil }
            return [optionalString(entry.pointee.path) ?? "", hex(entry.pointee.id), Int(entry.pointee.mode)]
        }
        return json(entries)
    }

    func indexAdd(_ path: String) throws(PythonError) {
        try check(git_index_add_bypath(try index(), path), notFound: path)
    }

    func indexAddAll(_ pathspecs: [String]) throws(PythonError) {
        let index = try index()
        try withStrarray(pathspecs) { (array) throws(PythonError) in
            try check(git_index_add_all(index, array, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
        }
    }

    func indexRemove(_ path: String) throws(PythonError) {
        try check(git_index_remove_bypath(try index(), path), notFound: path)
    }

    func indexRead(_ force: Bool) throws(PythonError) {
        try check(git_index_read(try index(), force ? 1 : 0))
    }

    func indexWrite() throws(PythonError) {
        try check(git_index_write(try index()))
    }

    /// Writes the index as a tree and returns the tree's id.
    func indexWriteTree() throws(PythonError) -> String {
        var id = git_oid()
        try check(git_index_write_tree(&id, try index()))
        return hex(id)
    }

    // MARK: Commits

    /// Creates a commit and returns its id. A signature is JSON with name,
    /// email, time and offset, a `null` time meaning now; `ref` may be `None`.
    func createCommit(
        _ ref: String?,
        _ author: String,
        _ committer: String,
        _ message: String,
        _ tree: String,
        _ parents: [String]
    ) throws(PythonError) -> String {
        let authorSignature = try signature(author)
        defer { git_signature_free(authorSignature) }
        let committerSignature = try signature(committer)
        defer { git_signature_free(committerSignature) }

        var treeId = try oid(tree)
        var treeObject: OpaquePointer?
        try check(git_tree_lookup(&treeObject, pointer, &treeId), notFound: tree)
        defer { git_tree_free(treeObject) }

        var parentObjects: [OpaquePointer?] = []
        defer { parentObjects.forEach { git_commit_free($0) } }
        for parent in parents {
            var parentId = try oid(parent)
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, pointer, &parentId), notFound: parent)
            parentObjects.append(commit)
        }

        var id = git_oid()
        let status = parentObjects.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(
                &id, pointer, ref, authorSignature, committerSignature, nil, message,
                treeObject, buffer.count, buffer.baseAddress
            )
        }
        try check(status)
        return hex(id)
    }

    private func signature(_ record: String) throws(PythonError) -> UnsafeMutablePointer<git_signature> {
        guard let fields = try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any],
              let name = fields["name"] as? String, let email = fields["email"] as? String else {
            throw .ValueError("a signature needs a name and an email")
        }
        var signature: UnsafeMutablePointer<git_signature>?
        if let time = fields["time"] as? Int {
            let offset = fields["offset"] as? Int ?? 0
            try check(git_signature_new(&signature, name, email, git_time_t(time), Int32(offset)))
        } else {
            try check(git_signature_now(&signature, name, email))
        }
        return signature!
    }

    /// The signature from user.name and user.email, as [name, email, time, offset].
    func defaultSignature() throws(PythonError) -> String {
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_default(&signature, pointer), notFound: "user.name and user.email aren't set")
        defer { git_signature_free(signature) }
        return json(signatureRecord(signature))
    }

    // MARK: Config

    func configGet(_ name: String) throws(PythonError) -> String {
        var config: OpaquePointer?
        try check(git_repository_config(&config, pointer))
        defer { git_config_free(config) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_config_get_string_buf(&buffer, config, name), notFound: name)
        return optionalString(buffer.ptr) ?? ""
    }

    func configSet(_ name: String, _ value: String) throws(PythonError) {
        var config: OpaquePointer?
        try check(git_repository_config(&config, pointer))
        defer { git_config_free(config) }
        try check(git_config_set_string(config, name, value))
    }

    func configDelete(_ name: String) throws(PythonError) {
        var config: OpaquePointer?
        try check(git_repository_config(&config, pointer))
        defer { git_config_free(config) }
        try check(git_config_delete_entry(config, name), notFound: name)
    }

    // MARK: Remotes

    func remoteNames() throws(PythonError) -> [String] {
        var array = git_strarray()
        try check(git_remote_list(&array, pointer))
        defer { git_strarray_dispose(&array) }
        return strings(of: array)
    }

    /// The remote's URL.
    func remoteUrl(_ name: String) throws(PythonError) -> String {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, pointer, name), notFound: name)
        defer { git_remote_free(remote) }
        return optionalString(git_remote_url(remote)) ?? ""
    }

    func createRemote(_ name: String, _ url: String) throws(PythonError) {
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, pointer, name, url))
        git_remote_free(remote)
    }

    func deleteRemote(_ name: String) throws(PythonError) {
        try check(git_remote_delete(pointer, name), notFound: name)
    }

    func setRemoteUrl(_ name: String, _ url: String) throws(PythonError) {
        try check(git_remote_set_url(pointer, name, url), notFound: name)
    }
}
