#!/usr/bin/env python3
"""Prove a module OUTSIDE this repository can build and run against chaossim.

Two modes, because "can a stranger use it" has two different answers:

  registry  (default now that 0.3.0 is published) the external module declares
            `PingGuoMiaoMiao/chaossim@<version>` and resolves it from MoonCakes -
            no path, no workspace file, nothing from this checkout
  local     the pre-publish mode: a workspace file pins the local checkout, which
            is how a consumer would depend on an unpublished project

`auto` (the default) tries registry first and falls back to local, saying which
one it used. Before publishing, only local could work; now registry is the honest
test, because a path dependency proves nothing about distribution.

Usage:
  python tools/consumer_check.py                # auto: registry, else local
  python tools/consumer_check.py --mode registry
  python tools/consumer_check.py --mode local
Exit: 0 = the external module built, ran and verified its replay artifact.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
MODULE = "PingGuoMiaoMiao/chaossim"

APP_MANIFEST = """name = "ext/app"

version = "0.1.0"

preferred_target = "native"

import {{
  "{module}@{version}",
}}
"""

APP_PKG = """import {{
  "{module}/sim",
}}

pkgtype(kind: "executable")
"""

APP_MAIN = r"""// Consumer living OUTSIDE the chaossim repository: depends on it by name,
// runs one fault scenario, then verifies the replay artifact it produced.

fn handler(node : Int32, msg : @sim.Msg) -> Array[@sim.Msg] {
  if msg.payload < 2 {
    [{ from: node, to: (msg.from + 1) % 2, payload: msg.payload + 1 }]
  } else {
    []
  }
}

fn main {
  let faults : Array[@sim.Fault] = [@sim.crash(1, 2)]
  let initial : Array[@sim.Msg] = [{ from: 0, to: 1, payload: 0 }]
  let r = @sim.run_bounded(handler, initial, 42, 20, faults) catch {
    e => {
      println("failed=\{e.message()}")
      return
    }
  }
  println("steps=\{r.steps} delivered=\{r.delivered} dropped=\{r.dropped}")
  let art = @sim.render_replay("ext-demo", 42, 20, initial, faults, r)
  println("replay_bytes=\{art.length()}")
  let again = @sim.replay_verify(art, handler) catch {
    e => {
      println("replay_failed=\{e.message()}")
      return
    }
  }
  println("verified_steps=\{again.steps}")
}
"""

REQUIRED = ("dropped=1", "verified_steps=", "replay_bytes=")


def run(args, cwd):
    return subprocess.run(
        args, cwd=cwd, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def manifest_version():
    for line in (PROJECT / "moon.mod").read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("version"):
            return line.split("=")[1].strip().strip('"')
    return "0.0.0"


def attempt(mode, version):
    """Write the consumer module for `mode`, run it, return (ok, output)."""
    work = Path(tempfile.mkdtemp(prefix=f"chaossim-consumer-{mode}-"))
    try:
        app = work / "app"
        (app / "src").mkdir(parents=True)
        (app / "moon.mod").write_text(
            APP_MANIFEST.format(module=MODULE, version=version), encoding="utf-8")
        (app / "src" / "moon.pkg").write_text(
            APP_PKG.format(module=MODULE), encoding="utf-8")
        (app / "src" / "main.mbt").write_text(APP_MAIN, encoding="utf-8")
        if mode == "local":
            # A workspace file is how a consumer points at a local checkout while
            # the package is unpublished.
            (work / "moon.work").write_text(
                'members = [\n  "app",\n  "%s",\n]\n'
                % str(PROJECT).replace("\\", "/"),
                encoding="utf-8",
            )
            target = "app/src"
            cwd = work
        else:
            # registry mode: the module stands alone, nothing from this checkout
            target = "src"
            cwd = app

        res = run(["moon", "run", target, "--target", "native"], cwd)
        output = res.stdout + res.stderr
        ok = res.returncode == 0 and all(m in res.stdout for m in REQUIRED)
        return ok, output, res.stdout
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("auto", "registry", "local"), default="auto")
    args = ap.parse_args()

    version = manifest_version()
    order = {"auto": ("registry", "local"), "registry": ("registry",),
             "local": ("local",)}[args.mode]

    for mode in order:
        print(f"consuming {MODULE}@{version} from a module outside the repository "
              f"(mode={mode})")
        ok, output, stdout = attempt(mode, version)
        if not ok and mode == "registry" and "not found in the registry" in output:
            # The local registry index is a cache; a fresh publish is invisible
            # until it is refreshed. Self-heal once instead of telling the user to
            # remember `moon update`.
            print("  registry index is stale for this version; running `moon update`")
            run(["moon", "update"], PROJECT)
            ok, output, stdout = attempt(mode, version)
        if ok:
            print("run output:")
            for line in stdout.strip().splitlines():
                print("  " + line)
            print(f"\nconsumer check passed via {mode}: an external module resolved "
                  f"chaossim by name, ran a fault scenario and verified its replay "
                  f"artifact")
            return 0
        tail = output.strip().splitlines()[-4:]
        print(f"  mode={mode} did not pass:")
        for line in tail:
            print("    " + line)
        if mode == "registry" and args.mode == "auto":
            print("  (falling back to local; a registry miss usually means this "
                  "version is not published yet)")

    print("\nconsumer check FAILED in every mode")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
