#!/usr/bin/env python3
"""Prove a module OUTSIDE this repository can build and run against chaossim.

chaossim is not published yet, so there is no registry version to resolve. What
can still be checked - and is checked here - is that a *separate* module with its
own `moon.mod`, living outside the repository, can depend on this project by
name, build, run a real fault scenario, and verify its own replay artifact.

A workspace file is used to point at the local checkout, which is exactly how a
consumer would pin a path dependency during development. When the package is
published this script should switch to resolving from the registry; the
`--version` flag records that intent.

Usage: python tools/consumer_check.py
Exit: 0 = the external module built, ran and verified its replay.
"""

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

APP_MAIN = """// Consumer living OUTSIDE the chaossim repository: depends on it by name,
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


def run(args, cwd):
    return subprocess.run(
        args, cwd=cwd, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="chaossim-consumer-"))
    try:
        app = work / "app"
        (app / "src").mkdir(parents=True)
        version = "0.3.0"
        for line in (PROJECT / "moon.mod").read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("version"):
                version = line.split("=")[1].strip().strip('"')
                break
        (app / "moon.mod").write_text(
            APP_MANIFEST.format(module=MODULE, version=version), encoding="utf-8"
        )
        (app / "src" / "moon.pkg").write_text(
            APP_PKG.format(module=MODULE), encoding="utf-8"
        )
        (app / "src" / "main.mbt").write_text(APP_MAIN, encoding="utf-8")
        # A workspace file is how a consumer points at a local checkout while the
        # package is unpublished.
        (work / "moon.work").write_text(
            'members = [\n  "app",\n  "%s",\n]\n'
            % str(PROJECT).replace("\\", "/"),
            encoding="utf-8",
        )

        print(f"consuming {MODULE}@{version} from a module outside the repository")
        res = run(["moon", "run", "app/src", "--target", "native"], work)
        if res.returncode != 0:
            print("FAIL build/run")
            print((res.stdout + res.stderr)[-1500:])
            return 1
        print("run output:")
        for line in res.stdout.strip().splitlines():
            print("  " + line)
        required = ("dropped=1", "verified_steps=", "replay_bytes=")
        missing = [m for m in required if m not in res.stdout]
        if missing:
            print(f"FAIL output missing: {missing}")
            return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("\nconsumer check passed: an external module resolved chaossim by name, "
          "ran a fault scenario and verified its replay artifact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
