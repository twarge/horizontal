"""The horizontal CLI these tests run: the one the MCP server would pick.

HORIZONTAL_CLI names one outright. Otherwise it is this checkout's release
build, then its debug one, the order find_cli takes; the release build is what
`make native`, and so `make python-test`, makes. It is found from this file
rather than from wherever the horizontal package was imported, and it has to be
newer than every Swift source in the checkout, so a stale binary fails here, by
name, rather than as tests of ops it predates.
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _cli() -> Path:
    named = os.environ.get("HORIZONTAL_CLI")
    if named:
        return Path(named).expanduser()
    built = [ROOT / ".build" / kind / "horizontal" for kind in ("release", "debug")]
    path = next((candidate for candidate in built if candidate.exists()), None)
    if path is None:
        raise RuntimeError(f"No horizontal CLI under {ROOT / '.build'}: run `make native`, "
                           "or point HORIZONTAL_CLI at one.")
    sources = list((ROOT / "Sources").rglob("*.swift"))
    if sources:
        newest = max(sources, key=lambda source: source.stat().st_mtime)
        if newest.stat().st_mtime > path.stat().st_mtime:
            raise RuntimeError(f"{path} was built before {newest.relative_to(ROOT)} changed: run `make native`, "
                               "or point HORIZONTAL_CLI at a current build.")
    return path


CLI = _cli()
