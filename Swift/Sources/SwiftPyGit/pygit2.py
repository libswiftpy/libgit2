"""Git repositories, with pygit2's API, on libgit2.

Read history, sync with remotes over HTTPS and commit, with the names pygit2
uses, so its examples run as written. SSH isn't available: use an HTTPS URL
with a token, from ``github.sign_in()`` or one kept in ``keychain``, such as
`pygit2.UserPass("x-access-token", keychain.secret("GITHUB_TOKEN"))`.

```python
import pygit2, github

callbacks = pygit2.RemoteCallbacks(credentials=github.credentials())
repo = pygit2.clone_repository("https://github.com/owner/project", "project", callbacks=callbacks)

for commit in repo.walk(repo.head.target, pygit2.enums.SortMode.TIME):
    print(commit.short_id, commit.message.splitlines()[0])
```
"""

import enum as _enum
import json as _json
import sys as _sys
import types as _types
from collections.abc import Callable, Iterable, Iterator
from os import PathLike
from typing import Any

import _pygit2

__version__ = "1.21.0-swiftpy"
LIBGIT2_VERSION = "1.9.2"

__all__ = [
    "GitError", "InvalidSpecError", "AlreadyExistsError", "Passthrough",
    "Oid", "Signature", "Object", "Commit", "Tree", "Blob", "Tag",
    "Reference", "Branch", "Remote", "RemoteCallbacks", "TransferProgress",
    "UserPass", "Username", "Index", "IndexEntry", "Config", "Walker",
    "Repository", "init_repository", "clone_repository", "enums",
]


# MARK: Errors

class GitError(Exception):
    """An error libgit2 reported."""


class InvalidSpecError(ValueError):
    """A reference name or revision spec that isn't valid."""


class AlreadyExistsError(ValueError):
    """An object, reference or remote that already exists."""


class Passthrough(Exception):
    """Raised from a callback to let libgit2 carry on without an answer."""


def _loads(text: str) -> Any:
    return _json.loads(text)


# MARK: Enums

class ObjectType(_enum.IntEnum):
    ANY = -2
    INVALID = -1
    COMMIT = 1
    TREE = 2
    BLOB = 3
    TAG = 4


class ResetMode(_enum.IntEnum):
    SOFT = 1
    MIXED = 2
    HARD = 3


class SortMode(_enum.IntFlag):
    NONE = 0
    TOPOLOGICAL = 1
    TIME = 2
    REVERSE = 4


class BranchType(_enum.IntEnum):
    LOCAL = 1
    REMOTE = 2
    ALL = 3


class ReferenceType(_enum.IntEnum):
    INVALID = 0
    DIRECT = 1
    SYMBOLIC = 2
    ALL = 3


class CredentialType(_enum.IntFlag):
    USERPASS_PLAINTEXT = 1
    SSH_KEY = 2
    SSH_CUSTOM = 4
    DEFAULT = 8
    SSH_INTERACTIVE = 16
    USERNAME = 32
    SSH_MEMORY = 64


class CheckoutStrategy(_enum.IntFlag):
    NONE = 0
    SAFE = 1
    FORCE = 2
    RECREATE_MISSING = 4
    ALLOW_CONFLICTS = 16
    REMOVE_UNTRACKED = 32
    REMOVE_IGNORED = 64
    UPDATE_ONLY = 128
    DONT_UPDATE_INDEX = 256
    NO_REFRESH = 512


class FileStatus(_enum.IntFlag):
    CURRENT = 0
    INDEX_NEW = 1
    INDEX_MODIFIED = 2
    INDEX_DELETED = 4
    INDEX_RENAMED = 8
    INDEX_TYPECHANGE = 16
    WT_NEW = 128
    WT_MODIFIED = 256
    WT_DELETED = 512
    WT_TYPECHANGE = 1024
    WT_RENAMED = 2048
    WT_UNREADABLE = 4096
    IGNORED = 16384
    CONFLICTED = 32768


class FetchPrune(_enum.IntEnum):
    UNSPECIFIED = 0
    PRUNE = 1
    NO_PRUNE = 2


class FileMode(_enum.IntFlag):
    UNREADABLE = 0
    TREE = 0o040000
    BLOB = 0o100644
    BLOB_EXECUTABLE = 0o100755
    LINK = 0o120000
    COMMIT = 0o160000


# `pygit2.enums`, importable as a module as in pygit2.
enums = _types.ModuleType("pygit2.enums", "The enumerations pygit2 uses.")
for _enum_type in (ObjectType, ResetMode, SortMode, BranchType, ReferenceType,
                   CredentialType, CheckoutStrategy, FileStatus, FileMode, FetchPrune):
    setattr(enums, _enum_type.__name__, _enum_type)
_sys.modules["pygit2.enums"] = enums

# pygit2's module-level constants for the same values.
for _prefix, _enum_type in (
    ("GIT_OBJECT_", ObjectType), ("GIT_RESET_", ResetMode), ("GIT_SORT_", SortMode),
    ("GIT_BRANCH_", BranchType), ("GIT_REF_", ReferenceType),
    ("GIT_CREDENTIAL_", CredentialType), ("GIT_CHECKOUT_", CheckoutStrategy),
    ("GIT_STATUS_", FileStatus), ("GIT_FILEMODE_", FileMode),
):
    for _member in _enum_type:
        globals()[_prefix + _member.name] = _member.value
GIT_FETCH_PRUNE_UNSPECIFIED = FetchPrune.UNSPECIFIED.value
GIT_FETCH_PRUNE = FetchPrune.PRUNE.value
GIT_FETCH_NO_PRUNE = FetchPrune.NO_PRUNE.value
del _prefix, _enum_type, _member


# MARK: Values

class Oid:
    """An object id: `Oid(hex="…")` or `Oid(raw=b"…")`."""

    __slots__ = ("_hex",)

    def __init__(self, raw: bytes | None = None, hex: str | None = None) -> None:
        if hex is None and raw is None:
            raise ValueError("Oid needs raw or hex")
        self._hex = hex.lower() if hex is not None else bytes(raw).hex()

    @property
    def hex(self) -> str:
        return self._hex

    @property
    def raw(self) -> bytes:
        return bytes.fromhex(self._hex)

    def __str__(self) -> str:
        return self._hex

    def __repr__(self) -> str:
        return f"{self._hex}"

    def __eq__(self, other: object) -> bool:
        if isinstance(other, Oid):
            return self._hex == other._hex
        if isinstance(other, str):
            return self._hex == other.lower()
        return NotImplemented

    def __lt__(self, other: "OidLike") -> bool:
        return self._hex < _hex(other)

    def __hash__(self) -> int:
        return hash(self._hex)

    def __bool__(self) -> bool:
        return self._hex.strip("0") != ""


# What names an object: an Oid, its hex, the object itself or a reference to it.
type OidLike = Oid | str | Object | Reference


def _hex(value: "OidLike") -> str:
    """The hex id of an Oid, an object, a reference or a string."""
    if isinstance(value, Oid):
        return value.hex
    if isinstance(value, Object):
        return value.id.hex
    if isinstance(value, Reference):
        return _hex(value.target)
    if isinstance(value, str):
        return value
    raise TypeError(f"expected an Oid or a hex string, not {type(value).__name__}")


class Signature:
    """Who made a commit and when: `Signature(name, email, time=-1, offset=0)`.
    A time of -1 means now."""

    def __init__(self, name: str, email: str, time: int = -1, offset: int = 0, encoding: str | None = None) -> None:
        self.name = name
        self.email = email
        if time == -1:
            # Now, with the local UTC offset in minutes, as pygit2 fills it in.
            import time as _time
            now = _time.time()
            time = int(now)
            offset = int(_time.localtime(now).tm_gmtoff // 60)
        self.time = time
        self.offset = offset
        self.encoding = encoding

    @classmethod
    def _from(cls, record: dict[str, Any] | None) -> "Signature | None":
        if record is None:
            return None
        return cls(record["name"], record["email"], record["time"], record["offset"])

    def _json(self) -> str:
        return _json.dumps({
            "name": self.name, "email": self.email,
            "time": self.time, "offset": self.offset,
        })

    @property
    def raw_name(self) -> bytes:
        return self.name.encode()

    @property
    def raw_email(self) -> bytes:
        return self.email.encode()

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Signature):
            return NotImplemented
        return (self.name, self.email, self.time, self.offset) == (other.name, other.email, other.time, other.offset)

    def __repr__(self) -> str:
        return f"pygit2.Signature({self.name!r}, {self.email!r}, {self.time}, {self.offset})"

    def __str__(self) -> str:
        return f"{self.name} <{self.email}>"


class TransferProgress:
    """How far a fetch or clone got."""

    def __init__(self, total_objects: int = 0, indexed_objects: int = 0, received_objects: int = 0,
                 local_objects: int = 0, total_deltas: int = 0, indexed_deltas: int = 0,
                 received_bytes: int = 0) -> None:
        self.total_objects = total_objects
        self.indexed_objects = indexed_objects
        self.received_objects = received_objects
        self.local_objects = local_objects
        self.total_deltas = total_deltas
        self.indexed_deltas = indexed_deltas
        self.received_bytes = received_bytes

    def __repr__(self) -> str:
        return (f"<TransferProgress {self.received_objects}/{self.total_objects} objects, "
                f"{self.received_bytes} bytes>")


# MARK: Objects

class Object:
    """A commit, tree, blob or tag. Entries of a tree also have a `name` and `filemode`."""

    def __init__(self, repo: "Repository", record: dict[str, Any], name: str | None = None,
                 filemode: int | None = None) -> None:
        self._repo = repo
        self._record = record
        self.name = name
        self.filemode = filemode

    @property
    def id(self) -> Oid:
        return Oid(hex=self._record["id"])

    @property
    def type(self) -> int:
        return self._record["type"]

    @property
    def type_str(self) -> str:
        return ObjectType(self.type).name.lower()

    @property
    def short_id(self) -> str:
        return self._record["id"][:7]

    def peel(self, target_type: "int | type[Object]") -> "Object":
        """The object this one peels to, such as a commit's tree or a tag's commit."""
        if isinstance(target_type, type) and issubclass(target_type, Object):
            target_type = _object_types[target_type]
        return self._repo[_pygit2_repo(self._repo).peel(self._record["id"], int(target_type))]

    def read_raw(self) -> bytes:
        """The object's content as git stores it."""
        return _pygit2_repo(self._repo).read_raw(self._record["id"])

    def __eq__(self, other: object) -> bool:
        if isinstance(other, Object):
            return self._record["id"] == other._record["id"]
        return NotImplemented

    def __hash__(self) -> int:
        return hash(self._record["id"])

    def __repr__(self) -> str:
        return f"<pygit2.Object{{{self.type_str}:{self._record['id']}}}>"


class Commit(Object):
    @property
    def message(self) -> str:
        return self._record["message"]

    @property
    def raw_message(self) -> bytes:
        return self.message.encode()

    @property
    def message_encoding(self) -> str | None:
        return None

    @property
    def author(self) -> Signature:
        return Signature._from(self._record["author"])

    @property
    def committer(self) -> Signature:
        return Signature._from(self._record["committer"])

    @property
    def parent_ids(self) -> list[Oid]:
        return [Oid(hex=parent) for parent in self._record["parents"]]

    @property
    def parents(self) -> list["Commit"]:
        return [self._repo[parent] for parent in self._record["parents"]]

    @property
    def tree_id(self) -> Oid:
        return Oid(hex=self._record["tree"])

    @property
    def tree(self) -> "Tree":
        return self._repo[self._record["tree"]]

    @property
    def commit_time(self) -> int:
        return self._record["commit_time"]

    @property
    def commit_time_offset(self) -> int:
        return self._record["commit_time_offset"]


class Tree(Object):
    def _entries(self) -> list[dict[str, Any]]:
        return self._record["entries"]

    def _object(self, entry: dict[str, Any]) -> Object:
        record = _loads(_pygit2_repo(self._repo).object(entry["id"])) if entry["type"] != ObjectType.COMMIT else {
            "id": entry["id"], "type": ObjectType.COMMIT, "message": "", "author": None, "committer": None,
            "parents": [], "tree": "0" * 40, "commit_time": 0, "commit_time_offset": 0,
        }
        return _wrap(self._repo, record, entry["name"], entry["filemode"])

    def __iter__(self) -> Iterator[Object]:
        return (self._object(entry) for entry in self._entries())

    def __len__(self) -> int:
        return len(self._entries())

    def __contains__(self, name: str) -> bool:
        if "/" in name:
            try:
                self[name]
                return True
            except KeyError:
                return False
        return any(entry["name"] == name for entry in self._entries())

    def __getitem__(self, key: int | str) -> Object:
        if isinstance(key, int):
            return self._object(self._entries()[key])
        if "/" in key:
            entry = _loads(_pygit2_repo(self._repo).tree_entry(self._record["id"], key))
            return self._object(entry)
        for entry in self._entries():
            if entry["name"] == key:
                return self._object(entry)
        raise KeyError(key)

    def __truediv__(self, name: str) -> Object:
        return self[name]


class Blob(Object):
    @property
    def data(self) -> bytes:
        return _pygit2_repo(self._repo).blob_data(self._record["id"])

    @property
    def size(self) -> int:
        return self._record["size"]

    @property
    def is_binary(self) -> bool:
        return self._record["is_binary"]


class Tag(Object):
    @property
    def message(self) -> str:
        return self._record["message"]

    @property
    def target(self) -> Oid:
        return Oid(hex=self._record["target"])

    @property
    def tagger(self) -> Signature | None:
        return Signature._from(self._record["tagger"])

    def get_object(self) -> Object:
        return self._repo[self._record["target"]]


_object_classes = {ObjectType.COMMIT: Commit, ObjectType.TREE: Tree, ObjectType.BLOB: Blob, ObjectType.TAG: Tag}
_object_types = {cls: value for value, cls in _object_classes.items()}


def _wrap(repo: "Repository", record: dict[str, Any], name: str | None = None,
          filemode: int | None = None) -> Object:
    cls = _object_classes.get(record["type"], Object)
    obj = cls(repo, record, name, filemode)
    if cls is Tag:
        obj.name = record["name"]
    return obj


def _pygit2_repo(repo: "Repository") -> Any:
    return repo._native


# MARK: References and branches

class Reference:
    """A name pointing at an object, or at another reference."""

    def __init__(self, repo: "Repository", record: dict[str, Any]) -> None:
        self._repo = repo
        self._record = record

    @property
    def name(self) -> str:
        return self._record["name"]

    @property
    def raw_name(self) -> bytes:
        return self.name.encode()

    @property
    def shorthand(self) -> str:
        return self._record["shorthand"]

    @property
    def type(self) -> int:
        return ReferenceType(self._record["type"])

    @property
    def target(self) -> "Oid | str | None":
        """An Oid for a direct reference, the name it points to for a symbolic one."""
        target = self._record["target"]
        if self._record["type"] == ReferenceType.SYMBOLIC:
            return target
        return Oid(hex=target) if target is not None else None

    def resolve(self) -> "Reference":
        record = _loads(self._repo._native.resolve_reference(self.name))
        return Reference(self._repo, record)

    def peel(self, type: "int | type[Object] | None" = None) -> Object:
        """The object the reference ends at, past any tags; or of `type`."""
        obj = self._repo[self.resolve().target]
        if type is not None:
            return obj.peel(type)
        while isinstance(obj, Tag):
            obj = obj.get_object()
        return obj

    def set_target(self, target: "OidLike", message: str | None = None) -> None:
        self._repo._native.set_reference_target(self.name, target if isinstance(target, str) and not _is_id(target) else _hex(target))
        self._record = _loads(self._repo._native.reference(self.name))

    def delete(self) -> None:
        self._repo._native.delete_reference(self.name)

    def __eq__(self, other: object) -> bool:
        if isinstance(other, Reference):
            return self.name == other.name and self._record["target"] == other._record["target"]
        return NotImplemented

    def __repr__(self) -> str:
        return f"<Reference {self.name} -> {self._record['target']}>"


def _is_id(text: str) -> bool:
    return len(text) in (40, 64) and all(c in "0123456789abcdefABCDEF" for c in text)


class Branch(Reference):
    def _info(self) -> dict[str, Any]:
        return _loads(self._repo._native.branch_info(self.name))

    @property
    def branch_name(self) -> str:
        return self._info()["branch_name"]

    @property
    def remote_name(self) -> str:
        """The remote a remote-tracking branch belongs to."""
        return self._repo._native.branch_remote_name(self.name)

    @property
    def upstream(self) -> "Branch | None":
        name = self._info()["upstream"]
        if name is None:
            return None
        return Branch(self._repo, _loads(self._repo._native.reference(name)))

    @upstream.setter
    def upstream(self, branch: "Branch | None") -> None:
        self._repo._native.set_upstream(self.name, None if branch is None else branch.shorthand)

    @property
    def upstream_name(self) -> str | None:
        return self._info()["upstream"]

    def is_head(self) -> bool:
        return self._info()["is_head"]

    def is_checked_out(self) -> bool:
        return self.is_head()

    def delete(self) -> None:
        self._repo._native.delete_branch(self.name)


class References:
    """`repo.references`: every reference, by full name."""

    def __init__(self, repo: "Repository") -> None:
        self._repo = repo

    def __iter__(self) -> Iterator[str]:
        return iter(self._repo._native.reference_names())

    def __contains__(self, name: str) -> bool:
        return self.get(name) is not None

    def __getitem__(self, name: str) -> Reference:
        return Reference(self._repo, _loads(self._repo._native.reference(name)))

    def get(self, name: str, default: Reference | None = None) -> Reference | None:
        try:
            return self[name]
        except KeyError:
            return default

    @property
    def objects(self) -> list[Reference]:
        return [self[name] for name in self]

    def create(self, name: str, target: "OidLike", force: bool = False) -> Reference:
        if isinstance(target, str) and not _is_id(target):
            record = self._repo._native.create_reference(name, target, force)
        else:
            record = self._repo._native.create_reference(name, _hex(target), force)
        return Reference(self._repo, _loads(record))

    def delete(self, name: str) -> None:
        self[name].delete()


class _BranchSet:
    def __init__(self, repo: "Repository", kind: BranchType, commit: str | None = None) -> None:
        self._repo = repo
        self._kind = kind
        self._commit = commit

    def with_commit(self, commit: "OidLike") -> "_BranchSet":
        """The branches whose history contains `commit`."""
        return _BranchSet(self._repo, self._kind, _hex(commit))

    def _contains_commit(self, refname: str) -> bool:
        target = _loads(self._repo._native.resolve_reference(refname))["target"]
        return target == self._commit or self._repo._native.descendant_of(target, self._commit)

    def _names(self) -> list[str]:
        kinds = [BranchType.LOCAL, BranchType.REMOTE] if self._kind == BranchType.ALL else [self._kind]
        names = []
        for kind in kinds:
            prefix = "refs/heads/" if kind == BranchType.LOCAL else "refs/remotes/"
            refnames = self._repo._native.branch_names(int(kind))
            if self._commit is not None:
                refnames = [name for name in refnames if self._contains_commit(name)]
            names += [name[len(prefix):] for name in refnames]
        return names

    def __iter__(self) -> Iterator[str]:
        return iter(self._names())

    def __len__(self) -> int:
        return len(self._names())

    def __contains__(self, name: str) -> bool:
        return self.get(name) is not None

    def __getitem__(self, name: str) -> Branch:
        kinds = [BranchType.LOCAL, BranchType.REMOTE] if self._kind == BranchType.ALL else [self._kind]
        for kind in kinds:
            try:
                refname = self._repo._native.branch(name, int(kind))
            except KeyError:
                continue
            return Branch(self._repo, _loads(self._repo._native.reference(refname)))
        raise KeyError(name)

    def get(self, name: str, default: Branch | None = None) -> Branch | None:
        try:
            return self[name]
        except KeyError:
            return default

    def delete(self, name: str) -> None:
        self[name].delete()


class Branches(_BranchSet):
    """`repo.branches`: local and remote branches by short name, with
    `.local` and `.remote` for one kind."""

    def __init__(self, repo: "Repository") -> None:
        super().__init__(repo, BranchType.ALL)
        self.local = _LocalBranches(repo)
        self.remote = _BranchSet(repo, BranchType.REMOTE)

    def create(self, name: str, commit: "OidLike", force: bool = False) -> Branch:
        return self.local.create(name, commit, force)


class _LocalBranches(_BranchSet):
    def __init__(self, repo: "Repository") -> None:
        super().__init__(repo, BranchType.LOCAL)

    def create(self, name: str, commit: "OidLike", force: bool = False) -> Branch:
        refname = self._repo._native.create_branch(name, _hex(commit), force)
        return Branch(self._repo, _loads(self._repo._native.reference(refname)))


# MARK: Remotes

class RemoteCallbacks:
    """What libgit2 asks during clone, fetch and push. Pass credentials, or
    subclass and override `credentials`, `transfer_progress` or
    `push_update_reference`.

    A `UserPass` password can be a ``keychain.Secret``: its value is filled in
    natively and never reaches Python.
    """

    def __init__(self, credentials: "Credential | Callable[..., Credential | None] | None" = None,
                 certificate: Any = None) -> None:
        if credentials is not None:
            self.credentials = credentials
        if certificate is not None:
            self.certificate = certificate

    def credentials(self, url: str, username_from_url: str | None,
                    allowed_types: CredentialType) -> "Credential | None":
        """Returns a credential object for `url`, or raises Passthrough."""
        raise Passthrough

    def transfer_progress(self, stats: TransferProgress) -> None:
        """Called as objects arrive."""

    def push_update_reference(self, refname: str, message: str | None) -> None:
        """Called for each pushed reference; `message` is why it was rejected."""
        if message is not None:
            raise GitError(f"{refname} push failed: {message}")

    # Called natively.

    def _git_credentials(self, url: str, username_from_url: str | None, allowed: int) -> list[Any] | None:
        credentials = self.credentials
        if credentials is None:
            return None
        if callable(credentials) and not hasattr(credentials, "credential_tuple"):
            try:
                credentials = credentials(url, username_from_url, CredentialType(allowed))
            except Passthrough:
                return None
        if credentials is None:
            return None
        if not allowed & credentials.credential_type:
            raise GitError("the credential type isn't one the remote allows")
        return [int(credentials.credential_type), *credentials.credential_tuple]

    def _git_transfer_progress(self, *counts: int) -> None:
        self.transfer_progress(TransferProgress(*counts))

    def _git_push_update_reference(self, refname: str, message: str | None) -> None:
        self.push_update_reference(refname, message)


class UserPass:
    """A username and password, or token, for HTTPS. The password may be a
    ``keychain.Secret``."""

    def __init__(self, username: str, password: Any) -> None:
        self._username = username
        self._password = password

    credential_type = CredentialType.USERPASS_PLAINTEXT

    @property
    def credential_tuple(self) -> tuple[str, Any]:
        return (self._username, self._password)

    def __call__(self, url: str, username_from_url: str | None, allowed_types: CredentialType) -> "UserPass":
        return self


class Username:
    """A username alone."""

    def __init__(self, username: str) -> None:
        self._username = username

    credential_type = CredentialType.USERNAME

    @property
    def credential_tuple(self) -> tuple[str]:
        return (self._username,)

    def __call__(self, url: str, username_from_url: str | None, allowed_types: CredentialType) -> "Username":
        return self


type Credential = UserPass | Username


class Remote:
    """A remote repository, such as `origin`."""

    def __init__(self, repo: "Repository", name: str) -> None:
        self._repo = repo
        self.name = name

    @property
    def url(self) -> str:
        return self._repo._native.remote_url(self.name)

    def fetch(self, refspecs: Iterable[str] | None = None, message: str | None = None,
              callbacks: RemoteCallbacks | None = None, prune: int = FetchPrune.UNSPECIFIED, proxy: Any = None,
              depth: int = 0) -> TransferProgress:
        """Downloads what the remote has, updating its remote branches.
        `prune=FetchPrune.PRUNE` removes those deleted on the remote; `depth`
        fetches only that many commits of history."""
        if isinstance(prune, bool):
            prune = FetchPrune.PRUNE if prune else FetchPrune.NO_PRUNE
        stats = _loads(_pygit2.fetch(
            self._repo._native, self.name, list(refspecs) if refspecs else None, int(prune), depth, callbacks
        ))
        return TransferProgress(**stats)

    @property
    def fetch_refspecs(self) -> list[str]:
        return list(self._repo._native.remote_refspecs(self.name, False))

    @property
    def push_refspecs(self) -> list[str]:
        return list(self._repo._native.remote_refspecs(self.name, True))

    def push(self, specs: Iterable[str], callbacks: RemoteCallbacks | None = None, proxy: Any = None,
             push_options: list[str] | None = None, threads: int = 1) -> None:
        """Uploads `specs`, such as ["refs/heads/main"]."""
        _pygit2.push(self._repo._native, self.name, list(specs), callbacks)

    def __repr__(self) -> str:
        return f"<Remote {self.name} {self.url}>"


class RemoteCollection:
    """`repo.remotes`: remotes by name or position."""

    def __init__(self, repo: "Repository") -> None:
        self._repo = repo

    def names(self) -> list[str]:
        return list(self._repo._native.remote_names())

    def __iter__(self) -> Iterator[Remote]:
        return (Remote(self._repo, name) for name in self.names())

    def __len__(self) -> int:
        return len(self.names())

    def __contains__(self, name: str) -> bool:
        return name in self.names()

    def __getitem__(self, key: int | str) -> Remote:
        names = self.names()
        if isinstance(key, int):
            return Remote(self._repo, names[key])
        if key not in names:
            raise KeyError(key)
        return Remote(self._repo, key)

    def create(self, name: str, url: str, fetch: str | None = None) -> Remote:
        self._repo._native.create_remote(name, url)
        return Remote(self._repo, name)

    def delete(self, name: str) -> None:
        self._repo._native.delete_remote(name)

    def set_url(self, name: str, url: str) -> None:
        self._repo._native.set_remote_url(name, url)


# MARK: Index and config

class IndexEntry:
    def __init__(self, path: str, id: "Oid | str", mode: int) -> None:
        self.path = path
        self.id = id if isinstance(id, Oid) else Oid(hex=id)
        self.mode = mode

    @property
    def hex(self) -> str:
        return self.id.hex

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, IndexEntry):
            return NotImplemented
        return (self.path, self.id, self.mode) == (other.path, other.id, other.mode)

    def __repr__(self) -> str:
        return f"<IndexEntry {self.path} {self.id.hex[:7]}>"


class Index:
    """`repo.index`: the staging area. Changes stay in memory until `write()`."""

    def __init__(self, repo: "Repository") -> None:
        self._repo = repo

    def _entries(self) -> list[IndexEntry]:
        return [IndexEntry(*entry) for entry in _loads(self._repo._native.index_entries())]

    def __iter__(self) -> Iterator[IndexEntry]:
        return iter(self._entries())

    def __len__(self) -> int:
        return len(self._entries())

    def __contains__(self, path: str) -> bool:
        return any(entry.path == path for entry in self._entries())

    def __getitem__(self, key: int | str) -> IndexEntry:
        entries = self._entries()
        if isinstance(key, int):
            return entries[key]
        for entry in entries:
            if entry.path == key:
                return entry
        raise KeyError(key)

    def add(self, path: "str | IndexEntry") -> None:
        self._repo._native.index_add(path.path if isinstance(path, IndexEntry) else str(path))

    def add_all(self, pathspecs: Iterable[str] | None = None) -> None:
        self._repo._native.index_add_all([str(spec) for spec in (pathspecs or [])])

    def remove(self, path: str) -> None:
        self._repo._native.index_remove(str(path))

    def read(self, force: bool = True) -> None:
        self._repo._native.index_read(force)

    def write(self) -> None:
        self._repo._native.index_write()

    def write_tree(self, repo: "Repository | None" = None) -> Oid:
        return Oid(hex=self._repo._native.index_write_tree())


class Config:
    """`repo.config`: settings such as user.name, read from every level and
    written to the repository's own."""

    def __init__(self, repo: "Repository") -> None:
        self._repo = repo

    def __getitem__(self, name: str) -> str:
        return self._repo._native.config_get(name)

    def __setitem__(self, name: str, value: str | int | bool) -> None:
        if isinstance(value, bool):
            value = "true" if value else "false"
        self._repo._native.config_set(name, str(value))

    def __delitem__(self, name: str) -> None:
        self._repo._native.config_delete(name)

    def __contains__(self, name: str) -> bool:
        try:
            self[name]
            return True
        except KeyError:
            return False

    def get(self, name: str, default: str | None = None) -> str | None:
        try:
            return self[name]
        except KeyError:
            return default

    def get_bool(self, name: str) -> bool:
        return self[name].lower() in ("true", "yes", "on", "1")

    def get_int(self, name: str) -> int:
        value = self[name].lower()
        scale = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}.get(value[-1:], 1)
        return int(value[:-1] if scale != 1 else value) * scale


# MARK: History

class Walker:
    """The commits from a starting point, as `repo.walk` returns them."""

    def __init__(self, repo: "Repository", oid: "OidLike | None", sort_mode: int = SortMode.NONE) -> None:
        self._repo = repo
        self._starts = [] if oid is None else [_hex(oid)]
        self._hidden = []
        self._sort = int(sort_mode)
        self._first_parent = False
        self._pending = None

    def _ids(self) -> list[str]:
        seen, ids = set(), []
        for start in self._starts:
            for commit in self._repo._native.walk(start, self._sort):
                if commit not in seen:
                    seen.add(commit)
                    ids.append(commit)
        hidden = set()
        for start in self._hidden:
            hidden.update(self._repo._native.walk(start, 0))
        ids = [commit for commit in ids if commit not in hidden]
        if self._first_parent and ids:
            chain, current = [], ids[0]
            while current is not None and current not in hidden:
                chain.append(current)
                parents = self._repo[current]._record["parents"]
                current = parents[0] if parents else None
            ids = chain
        return ids

    def push(self, oid: "OidLike") -> None:
        self._starts.append(_hex(oid))

    def hide(self, oid: "OidLike") -> None:
        self._hidden.append(_hex(oid))

    def sort(self, sort_mode: int) -> None:
        self._sort = int(sort_mode)

    def reset(self) -> None:
        self._starts, self._hidden, self._pending = [], [], None

    def simplify_first_parent(self) -> None:
        self._first_parent = True

    def __iter__(self) -> "Walker":
        self._pending = iter(self._ids())
        return self

    def __next__(self) -> Commit:
        if self._pending is None:
            self._pending = iter(self._ids())
        return self._repo[next(self._pending)]


# MARK: Repository

class Repository:
    """A Git repository: `Repository(path)` opens the one at or above `path`."""

    def __init__(self, path: "str | PathLike[str] | None" = None, flags: int = 0) -> None:
        try:
            native = _pygit2.open_repository(str(path))
        except KeyError as error:
            raise GitError(f"Repository not found at {path}") from error
        self._adopt(native)

    @classmethod
    def _wrapping(cls, native: Any) -> "Repository":
        """Around a repository the native side already opened, as init and
        clone return it, without opening it again."""
        repo = cls.__new__(cls)
        repo._adopt(native)
        return repo

    def _adopt(self, native: Any) -> None:
        self._native = native
        self._index = None

    def _info(self) -> dict[str, Any]:
        return _loads(self._native.info())

    @property
    def path(self) -> str:
        return self._info()["path"]

    @property
    def workdir(self) -> str | None:
        return self._info()["workdir"]

    @property
    def is_bare(self) -> bool:
        return self._info()["is_bare"]

    @property
    def is_empty(self) -> bool:
        return self._info()["is_empty"]

    @property
    def head_is_unborn(self) -> bool:
        return self._info()["head_is_unborn"]

    @property
    def head_is_detached(self) -> bool:
        return self._info()["head_is_detached"]

    @property
    def head(self) -> Reference:
        """The reference HEAD resolves to; raises GitError on an unborn branch."""
        try:
            return Reference(self, _loads(self._native.resolve_reference("HEAD")))
        except KeyError as error:
            target = _loads(self._native.reference("HEAD"))["target"]
            raise GitError(f"reference '{target}' not found") from error

    @property
    def references(self) -> References:
        return References(self)

    @property
    def branches(self) -> Branches:
        return Branches(self)

    @property
    def remotes(self) -> RemoteCollection:
        return RemoteCollection(self)

    @property
    def index(self) -> Index:
        if self._index is None:
            self._index = Index(self)
        return self._index

    @property
    def config(self) -> Config:
        return Config(self)

    @property
    def default_signature(self) -> Signature:
        return Signature._from(_loads(self._native.default_signature()))

    # Objects

    def _lookup(self, key: "OidLike") -> Object:
        key = _hex(key)
        if _is_id(key):
            return _wrap(self, _loads(self._native.object(key)))
        try:
            return _wrap(self, _loads(self._native.object(self._native.revparse(key))))
        except ValueError as error:
            raise KeyError(key) from error

    def __getitem__(self, key: "OidLike") -> Object:
        return self._lookup(key)

    def get(self, key: "OidLike", default: Object | None = None) -> Object | None:
        try:
            return self._lookup(key)
        except (KeyError, ValueError):
            return default

    def __contains__(self, key: "OidLike") -> bool:
        return self.get(key) is not None

    def revparse_single(self, revision: str) -> Object:
        return self._lookup(self._native.revparse(revision))

    def create_blob(self, data: bytes | str) -> Oid:
        if isinstance(data, str):
            data = data.encode()
        return Oid(hex=self._native.create_blob(bytes(data)))

    # References

    def lookup_reference(self, name: str) -> Reference:
        return self.references[name]

    def create_reference(self, name: str, target: "OidLike", force: bool = False,
                         message: str | None = None) -> Reference:
        return self.references.create(name, target, force)

    def lookup_branch(self, name: str, branch_type: int = BranchType.LOCAL) -> Branch | None:
        return _BranchSet(self, BranchType(branch_type)).get(name)

    def create_branch(self, name: str, commit: "OidLike", force: bool = False) -> Branch:
        return self.branches.local.create(name, commit, force)

    def listall_references(self) -> list[str]:
        return list(self.references)

    def listall_reference_objects(self) -> list[Reference]:
        return self.references.objects

    def listall_branches(self, flag: int = BranchType.LOCAL) -> list[str]:
        return list(_BranchSet(self, BranchType(flag)))

    def create_tag(self, name: str, oid: "OidLike", type: int, tagger: Signature, message: str) -> Oid:
        """Creates an annotated tag of the object `oid`; `type` is its ObjectType."""
        return Oid(hex=self._native.create_tag(name, _hex(oid), tagger._json(), message, False))

    def path_is_ignored(self, path: str) -> bool:
        return self._native.path_is_ignored(path)

    def descendant_of(self, oid: "OidLike", ancestor: "OidLike") -> bool:
        """Whether `ancestor` is in the history of `oid`, not counting `oid` itself."""
        return self._native.descendant_of(_hex(oid), _hex(ancestor))

    def set_head(self, target: "OidLike") -> None:
        self._native.set_head(target if isinstance(target, str) and not _is_id(target) else _hex(target))

    # History and working tree

    def walk(self, oid: "OidLike | None" = None, sort_mode: int = SortMode.NONE) -> Walker:
        return Walker(self, oid, sort_mode)

    def status(self, untracked_files: str = "all", ignored: bool = False) -> dict[str, FileStatus]:
        return {path: FileStatus(flags) for path, flags in self._native.status(untracked_files, ignored).items()}

    def status_file(self, path: str) -> FileStatus:
        return FileStatus(self._native.status_file(path))

    def checkout(self, refname: "str | Reference | None" = None, strategy: int = CheckoutStrategy.SAFE,
                 **kwargs: Any) -> None:
        """Checks out a branch or reference, moving HEAD to it; with no name,
        updates the working tree to HEAD."""
        if isinstance(refname, Reference):
            refname = refname.name
        self._native.checkout(refname, int(strategy))

    def checkout_head(self, strategy: int = CheckoutStrategy.SAFE, **kwargs: Any) -> None:
        self._native.checkout(None, int(strategy))

    def reset(self, oid: "OidLike", reset_type: int) -> None:
        self._native.reset(_hex(oid), int(reset_type))

    def create_commit(self, reference_name: str | None, author: Signature, committer: Signature,
                      message: str, tree: "OidLike", parents: "Iterable[OidLike]") -> Oid:
        """Writes a commit of `tree` and moves `reference_name` (such as "HEAD")
        to it; `None` leaves every reference where it is."""
        return Oid(hex=self._native.create_commit(
            reference_name, author._json(), committer._json(), message, _hex(tree), [_hex(parent) for parent in parents]
        ))

    def __repr__(self) -> str:
        return f"pygit2.Repository({self.path!r})"


def init_repository(path: "str | PathLike[str]", bare: bool = False, flags: int = 0, mode: int = 0,
                    workdir_path: str | None = None, description: str | None = None,
                    template_path: str | None = None, initial_head: str | None = None,
                    origin_url: str | None = None) -> Repository:
    """Creates a repository at `path`, or reopens the one there."""
    repo = Repository._wrapping(_pygit2.init_repository(str(path), bare))
    if initial_head is not None:
        repo._native.set_head(initial_head if initial_head.startswith("refs/") else f"refs/heads/{initial_head}")
    if origin_url is not None:
        repo.remotes.create("origin", origin_url)
    return repo


def clone_repository(url: str, path: "str | PathLike[str]", bare: bool = False, repository: Any = None,
                     remote: Any = None, checkout_branch: str | None = None,
                     callbacks: RemoteCallbacks | None = None, depth: int = 0, proxy: Any = None) -> Repository:
    """Clones the repository at `url` into `path` over HTTPS."""
    return Repository._wrapping(_pygit2.clone(url, str(path), bare, checkout_branch, depth, callbacks))

