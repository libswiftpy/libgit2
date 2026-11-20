"""GitHub sign-in, for pygit2 and requests.

`sign_in()` saves the account's token in the keychain as `GITHUB_TOKEN`, so
it works wherever a ``keychain.Secret`` does, and its value never reaches
Python. Without signing in, a token saved under that name works the same.

```python
import github, pygit2

github.sign_in()
callbacks = pygit2.RemoteCallbacks(credentials=github.credentials())
repo = pygit2.clone_repository("https://github.com/owner/project", "project", callbacks=callbacks)
```"""

import _github
import keychain
from _github import account, sign_out

__all__ = ["account", "create_repository", "credentials", "sign_out", "token"]

# Bound only where signing in is offered.
if hasattr(_github, "sign_in"):
    from _github import sign_in

    __all__ += ["sign_in"]


def create_repository(name: str, private: bool = True) -> str:
    """Creates an empty repository on the signed-in account and returns its
    HTTPS URL, to add as a remote and push to.

    name: The repository's name.
    private: Whether only you, and those you invite, can see it. Defaults to True.
    """
    return _github.create_repository(name, private)


def token() -> keychain.Secret:
    """The GitHub token, as the keychain secret `GITHUB_TOKEN`.

    ```python
    import github, requests

    response = requests.get(
        "https://api.github.com/user/repos",
        headers={"Authorization": github.token().bearer()},
    )
    ```
    """
    return keychain.Secret("GITHUB_TOKEN")


def credentials():
    """HTTPS credentials for pygit2's remote callbacks, with the GitHub token."""
    import pygit2

    return pygit2.UserPass("x-access-token", token())
