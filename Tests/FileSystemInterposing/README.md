# File-system interposing regression

Requires macOS, Xcode command-line tools, Python 3, and a local checkout of
[facebook/fishhook](https://github.com/facebook/fishhook). Tested with fishhook
commit `aadc161ac3b80db07a9908851839a17ba63a9eb1`.

```sh
python3 Tests/FileSystemInterposing/run.py --fishhook-dir /path/to/fishhook
```

The runner extracts the actual C wrappers from `PlayTools/PlayLoader.m` and
compiles them into a small interposing library. A separate executable installs
fishhook resource-loader hooks and forwards through each saved original pointer.
The test checks existing and missing files, error propagation, eight concurrent
readers, and preservation of Unreal's path repair. No game files are required.
The fixture supplies a deterministic login name to the path helper, so command
runner login sessions do not affect the Unreal path cases.

To prove the regression against the unmodified source:

```sh
git show origin/master:PlayTools/PlayLoader.m > /tmp/PlayLoader-before.m
python3 Tests/FileSystemInterposing/run.py --fishhook-dir /path/to/fishhook \
  --source /tmp/PlayLoader-before.m --expect-recursion
```

Each old wrapper must exit with the recursion sentinel (42). Each fixed wrapper
must complete successfully. The runner does not download dependencies or change
the installed PlayTools framework.
