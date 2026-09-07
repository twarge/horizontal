"""Transports to the dispatch layer: in-process (ctypes) and subprocess."""

from __future__ import annotations

import ctypes
import json
import os
import shutil
import subprocess
import threading
import time
import socket
import select
from contextlib import contextmanager
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

    def structured(self) -> dict[str, Any]:
        data = self.data if isinstance(self.data, dict) else {}
        return {"code": data.get("code", "ENGINE_ERROR"), "message": self.message,
                "native_code": self.code, "details": data.get("details", {}),
                "retryable": data.get("retryable", False), "outcome": data.get("outcome", "unknown")}

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
    timeout: float = 30
    max_bytes = 64 * 1024 * 1024
    closed = False
    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    def close(self) -> None:
        pass


def transport_error(label: str, message: str, request: dict[str, Any] | None = None,
                    outcome: str = "not_sent") -> HorizontalError:
    return HorizontalError(-32004 if label == "TIMEOUT" else -32603, message,
                           {"code": label, "retryable": label in {"TIMEOUT", "CONNECTION_LOST"},
                            "outcome": outcome, "details": {"operation_id": (request or {}).get("params", {}).get("operation_id")}})


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Operation deadline exceeded")
    return remaining


def _deadline(request: dict[str, Any], timeout: float) -> float:
    remaining = request.get("deadline_unix_ms", (time.time() + timeout) * 1000) / 1000 - time.time()
    return time.monotonic() + min(timeout, max(0, remaining))


@contextmanager
def _locked(lock: threading.Lock, deadline: float):
    if not lock.acquire(timeout=max(0, deadline - time.monotonic())):
        raise transport_error("TIMEOUT", "Timed out waiting for the transport lock.")
    try:
        yield
    finally:
        lock.release()


def _decode(line: bytes, request: dict[str, Any]) -> dict[str, Any]:
    response = json.loads(line)
    if (not isinstance(response, dict) or response.get("jsonrpc") != "2.0"
            or response.get("id") != request["id"] or ("result" in response) == ("error" in response)):
        raise ValueError("Malformed or mismatched JSON-RPC response")
    return response


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
        with _locked(self._lock, _deadline(request, self.timeout)):
            pointer = self._lib.horizontal_call(payload)
            if not pointer:
                raise HorizontalError(-32603, "The dispatch call returned no response.")
            try:
                text = ctypes.string_at(pointer).decode("utf-8")
            finally:
                self._lib.horizontal_free(pointer)
        return _decode(text.encode(), request)


class SubprocessTransport(Transport):
    """Runs `horizontal serve` and speaks newline-delimited JSON-RPC to it."""

    def __init__(self, cli: Path, timeout: float = 30):
        self.path = cli
        self.timeout = timeout
        self._process = subprocess.Popen(
            [str(cli), "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            bufsize=0,
        )
        self._lock = threading.Lock()
        assert self._process.stdin and self._process.stdout
        os.set_blocking(self._process.stdin.fileno(), False)
        os.set_blocking(self._process.stdout.fileno(), False)

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        assert self._process.stdin and self._process.stdout
        deadline = _deadline(request, self.timeout)
        sent = False
        with _locked(self._lock, deadline):
            try:
                if self.closed or self._process.poll() is not None:
                    raise ConnectionError("The horizontal worker is closed.")
                payload = (json.dumps(request, allow_nan=False) + "\n").encode()
                if len(payload) > 16 * 1024 * 1024:
                    raise ValueError("Request exceeds 16 MiB.")
                offset = 0
                while offset < len(payload):
                    if not select.select([], [self._process.stdin], [], _remaining(deadline))[1]:
                        raise TimeoutError("Worker write timed out")
                    sent = True
                    offset += os.write(self._process.stdin.fileno(), payload[offset:])
                response = bytearray()
                while b"\n" not in response:
                    if not select.select([self._process.stdout], [], [], _remaining(deadline))[0]:
                        raise TimeoutError("Worker response timed out")
                    chunk = os.read(self._process.stdout.fileno(), 65536)
                    if not chunk:
                        raise ConnectionError("Worker closed its output")
                    response.extend(chunk)
                    if len(response) > self.max_bytes:
                        raise ValueError("Worker response exceeds 64 MiB")
                line, rest = response.split(b"\n", 1)
                if rest.strip():
                    raise ValueError("Unexpected extra response")
                return _decode(line, request)
            except (OSError, ValueError) as error:
                self.close()
                raise transport_error("TIMEOUT" if isinstance(error, TimeoutError) else "CONNECTION_LOST",
                                      str(error), request, "indeterminate" if sent else "not_sent") from error

    def close(self) -> None:
        self.closed = True
        if self._process.poll() is None:
            try:
                if self._process.stdin:
                    self._process.stdin.close()
                self._process.wait(timeout=0.2)
            except Exception:
                self._process.kill()
                self._process.wait(timeout=2)
        for pipe in (self._process.stdin, self._process.stdout):
            if pipe:
                pipe.close()


LIVE_BUNDLE_ID = "com.twarge.app.horizontal"


def live_discovery_paths() -> list[Path]:
    env = os.environ.get("HORIZONTAL_LIVE")
    paths = [Path(env).expanduser()] if env else []
    home = Path.home()
    paths.append(home / "Library" / "Containers" / LIVE_BUNDLE_ID / "Data" / "Library" / "Application Support" / "Horizontal" / "live.json")
    paths.append(home / "Library" / "Application Support" / "Horizontal" / "live.json")
    return paths


def find_live(diagnostics: list[dict[str, Any]] | None = None) -> dict[str, Any] | None:
    """The running app's live channel (port and token), if it is up."""
    import socket

    for path in live_discovery_paths():
        try:
            info = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            if diagnostics is not None: diagnostics.append({"path": str(path), "status": "unavailable", "reason": str(error)})
            continue
        if not isinstance(info, dict):
            if diagnostics is not None: diagnostics.append({"path": str(path), "status": "invalid_discovery"})
            continue
        port = info.get("port")
        token = info.get("token")
        if (not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535
                or not isinstance(token, str) or not token or info.get("host", "127.0.0.1") != "127.0.0.1"):
            if diagnostics is not None: diagnostics.append({"path": str(path), "status": "invalid_discovery"})
            continue
        # A stale file outlives a crashed app; only report a listener that answers.
        try:
            with socket.create_connection((info.get("host", "127.0.0.1"), int(port)), timeout=0.5):
                pass
        except OSError as error:
            if diagnostics is not None: diagnostics.append({"path": str(path), "status": "unreachable", "reason": str(error)})
            continue
        info["path"] = str(path)
        return info
    return None


class LiveTransport(Transport):
    """Newline-delimited JSON-RPC over the app's loopback socket."""

    def __init__(self, info: dict[str, Any], timeout: float = 30):
        import socket

        self.info = info
        self.timeout = timeout
        self.path = f"{info.get('host', '127.0.0.1')}:{info['port']}"
        self._token = info["token"]
        self._socket = socket.create_connection((info.get("host", "127.0.0.1"), int(info["port"])), timeout=min(3, timeout))
        self._lock = threading.Lock()

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        request = dict(request)
        request["auth"] = self._token
        deadline = _deadline(request, self.timeout)
        sent = False
        with _locked(self._lock, deadline):
            try:
                if self.closed:
                    raise ConnectionError("Live connection is closed")
                payload = (json.dumps(request, allow_nan=False) + "\n").encode()
                if len(payload) > 16 * 1024 * 1024:
                    raise ValueError("Request exceeds 16 MiB")
                self._socket.settimeout(_remaining(deadline))
                sent = True
                self._socket.sendall(payload)
                response = bytearray()
                while b"\n" not in response:
                    self._socket.settimeout(_remaining(deadline))
                    chunk = self._socket.recv(65536)
                    if not chunk: raise ConnectionError("Horizontal closed the live channel")
                    response.extend(chunk)
                    if len(response) > self.max_bytes: raise ValueError("Live response exceeds 64 MiB")
                line, rest = response.split(b"\n", 1)
                if rest.strip(): raise ValueError("Unexpected extra response")
                return _decode(line, request)
            except (OSError, ValueError) as error:
                self.close()
                raise transport_error("TIMEOUT" if isinstance(error, TimeoutError) else "CONNECTION_LOST",
                                      str(error), request, "indeterminate" if sent else "not_sent") from error

    def close(self) -> None:
        self.closed = True
        try:
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
