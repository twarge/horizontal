"""Transports to the dispatch layer: in-process (ctypes) and subprocess."""

from __future__ import annotations

import ctypes
import json
import os
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Any

DYLIB_NAME = "libHorizontalPy.dylib"
CLI_NAME = "horizontal"


class HorizontalError(Exception):
    """A JSON-RPC error returned by the dispatch layer."""

    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data

    def __str__(self) -> str:  # pragma: no cover - trivial
        return f"{self.message} (code {self.code})"


def _repo_build_dirs() -> list[Path]:
    """`.build/{release,debug}` of the checkout this file lives in, if any."""
    here = Path(__file__).resolve()
    candidates = []
    for parent in here.parents:
        build = parent / ".build"
        if build.is_dir():
            candidates.extend([build / "release", build / "debug"])
            break
    return candidates


def find_dylib() -> Path | None:
    env = os.environ.get("HORIZONTAL_DYLIB")
    if env:
        path = Path(env).expanduser()
        return path if path.exists() else None
    search = [Path(__file__).resolve().parent / "lib"]
    search.extend(_repo_build_dirs())
    search.extend([Path.home() / ".horizontal" / "lib", Path("/usr/local/lib"), Path("/opt/homebrew/lib")])
    for directory in search:
        candidate = directory / DYLIB_NAME
        if candidate.exists():
            return candidate
    return None


def find_cli() -> Path | None:
    env = os.environ.get("HORIZONTAL_CLI")
    if env:
        path = Path(env).expanduser()
        return path if path.exists() else None
    for directory in _repo_build_dirs():
        candidate = directory / CLI_NAME
        if candidate.exists():
            return candidate
    found = shutil.which(CLI_NAME)
    return Path(found) if found else None


class Transport:
    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    def close(self) -> None:
        pass


class InProcessTransport(Transport):
    """Loads the dylib and calls `horizontal_call` directly."""

    def __init__(self, dylib: Path):
        self.path = dylib
        self._lib = ctypes.CDLL(str(dylib))
        self._lib.horizontal_call.argtypes = [ctypes.c_char_p]
        self._lib.horizontal_call.restype = ctypes.c_void_p
        self._lib.horizontal_free.argtypes = [ctypes.c_void_p]
        self._lib.horizontal_free.restype = None
        self._lib.horizontal_api_version.restype = ctypes.c_int32
        self._lock = threading.Lock()
        self.api_version = int(self._lib.horizontal_api_version())

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        payload = json.dumps(request).encode("utf-8")
        with self._lock:
            pointer = self._lib.horizontal_call(payload)
            if not pointer:
                raise HorizontalError(-32603, "The dispatch call returned no response.")
            try:
                text = ctypes.string_at(pointer).decode("utf-8")
            finally:
                self._lib.horizontal_free(pointer)
        return json.loads(text)


class SubprocessTransport(Transport):
    """Runs `horizontal serve` and speaks newline-delimited JSON-RPC to it."""

    def __init__(self, cli: Path):
        self.path = cli
        self._process = subprocess.Popen(
            [str(cli), "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._lock = threading.Lock()

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        assert self._process.stdin and self._process.stdout
        with self._lock:
            if self._process.poll() is not None:
                raise HorizontalError(-32603, f"The horizontal server exited with status {self._process.returncode}.")
            self._process.stdin.write(json.dumps(request) + "\n")
            self._process.stdin.flush()
            line = self._process.stdout.readline()
        if not line:
            raise HorizontalError(-32603, "The horizontal server closed its output.")
        return json.loads(line)

    def close(self) -> None:
        if self._process.poll() is None:
            try:
                if self._process.stdin:
                    self._process.stdin.close()
                self._process.wait(timeout=5)
            except Exception:
                self._process.kill()


LIVE_BUNDLE_ID = "com.twarge.app.horizontal"


def live_discovery_paths() -> list[Path]:
    env = os.environ.get("HORIZONTAL_LIVE")
    paths = [Path(env).expanduser()] if env else []
    home = Path.home()
    paths.append(home / "Library" / "Containers" / LIVE_BUNDLE_ID / "Data" / "Library" / "Application Support" / "Horizontal" / "live.json")
    paths.append(home / "Library" / "Application Support" / "Horizontal" / "live.json")
    return paths


def find_live() -> dict[str, Any] | None:
    """The running app's live channel (port and token), if it is up."""
    import socket

    for path in live_discovery_paths():
        try:
            info = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        port = info.get("port")
        token = info.get("token")
        if not port or not token:
            continue
        # A stale file outlives a crashed app; only report a listener that answers.
        try:
            with socket.create_connection((info.get("host", "127.0.0.1"), int(port)), timeout=0.5):
                pass
        except OSError:
            continue
        info["path"] = str(path)
        return info
    return None


class LiveTransport(Transport):
    """Newline-delimited JSON-RPC over the app's loopback socket."""

    def __init__(self, info: dict[str, Any]):
        import socket

        self.info = info
        self.path = f"{info.get('host', '127.0.0.1')}:{info['port']}"
        self._token = info["token"]
        self._socket = socket.create_connection((info.get("host", "127.0.0.1"), int(info["port"])), timeout=120)
        self._file = self._socket.makefile("rw", encoding="utf-8", newline="\n")
        self._lock = threading.Lock()

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        request = dict(request)
        request["auth"] = self._token
        with self._lock:
            self._file.write(json.dumps(request) + "\n")
            self._file.flush()
            line = self._file.readline()
        if not line:
            raise HorizontalError(-32603, "Horizontal closed the live channel.")
        return json.loads(line)

    def close(self) -> None:
        try:
            self._file.close()
            self._socket.close()
        except OSError:
            pass


def default_transport(isolated: bool = False) -> Transport:
    if not isolated:
        dylib = find_dylib()
        if dylib:
            return InProcessTransport(dylib)
    cli = find_cli()
    if cli:
        return SubprocessTransport(cli)
    raise HorizontalError(
        -32603,
        "Neither libHorizontalPy.dylib nor the horizontal command line tool was found. "
        "Build them in the Horizontal checkout with `swift build -c release --product HorizontalPy && swift build -c release --product horizontal`, "
        "or point HORIZONTAL_DYLIB / HORIZONTAL_CLI at them.",
    )
