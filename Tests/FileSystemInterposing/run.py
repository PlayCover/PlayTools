#!/usr/bin/env python3
"""Exercise PlayLoader's actual C wrappers against a fishhook resource loader."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fishhook-dir", type=Path, required=True)
parser.add_argument("--source", type=Path, help="Alternative PlayLoader.m, e.g. before the fix")
parser.add_argument("--expect-recursion", action="store_true")
args = parser.parse_args()
here = Path(__file__).resolve().parent
repo = here.parent.parent
source = (args.source or repo / "PlayTools/PlayLoader.m").read_text()
# Compile the production wrappers without the unrelated UIKit/Swift loader.
wrappers = source[source.index("static uint8_t ue_status"):source.index("static NSMutableDictionary *thread_sleep_counters")]
symbols = ("open", "stat", "access", "rename", "unlink")
interposes = "\n".join(
    f"__attribute__((used,section(\"__DATA,__interpose\"))) static struct {{ const void *a, *b; }} "
    f"ip_{name} = {{(const void *)&pt_{name}, (const void *)&{name}}};"
    for name in symbols
)
includes = """#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
"""
# Command runners can have a different login session from the desktop user.
# Give the existing Unreal path helper a deterministic fixture username.
assert repo.parts[1] == "Users", "Run this fixture from a macOS home directory"
includes += (
    f"static int fixture_login(char *buf, size_t size) {{\n"
    f"    strlcpy(buf, {json.dumps(repo.parts[2])}, size); return 0;\n}}\n"
    "#define getlogin_r fixture_login\n"
)
with tempfile.TemporaryDirectory(prefix="filesystem-interpose-", dir=repo.parent) as tmp:
    root = Path(tmp)
    library = root / "wrappers.dylib"
    test = root / "regression"
    (root / "wrappers.c").write_text(includes + wrappers + interposes + "\nvoid test_unreal(void) { ue_status = 2; }\n")
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-dynamiclib", "-O2",
                    str(root / "wrappers.c"), "-o", str(library)], check=True)
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", "-pthread",
                    "-I", str(args.fishhook_dir), str(here / "regression.c"),
                    str(args.fishhook_dir / "fishhook.c"), "-o", str(test)], check=True)
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library))
    for symbol in symbols:
        for unreal in (False, True):
            command = [str(test), symbol, str(root), "unreal" if unreal else "normal"]
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
            expected = 42 if args.expect_recursion else 0
            label = f"{symbol} ({'Unreal path repair' if unreal else 'unchanged path'})"
            if result.returncode != expected:
                raise SystemExit(f"FAIL: {label}: exit {result.returncode}, expected {expected}\n{result.stdout}{result.stderr}")
            print(f"PASS: {label}" + (" reproduces recursion" if args.expect_recursion else ""))
