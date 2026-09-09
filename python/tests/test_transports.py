import json
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from horizontal._native import (HorizontalError, LiveTransport, SubprocessTransport, Transport,
                                find_live_for, project_holders, transport_error)
from horizontal.client import Session, Project, open as open_project


class TransportTests(unittest.TestCase):
    def request(self): return {"jsonrpc": "2.0", "id": 7, "method": "apply", "params": {"operation_id": "receipt"}}

    def live(self, timeout=.1):
        client, server = socket.socketpair()
        self.addCleanup(server.close)
        with patch("socket.create_connection", return_value=client):
            transport = LiveTransport({"host": "127.0.0.1", "port": 1, "token": "secret"}, timeout=timeout)
        self.addCleanup(transport.close)
        return transport, server

    def test_live_timeout_closes_connection_and_marks_uncertainty(self):
        transport, server = self.live()
        start = time.monotonic()
        with self.assertRaises(HorizontalError) as caught: transport.call(self.request())
        self.assertLess(time.monotonic() - start, .5)
        self.assertTrue(transport.closed)
        self.assertEqual(caught.exception.structured()["outcome"], "indeterminate")
        self.assertEqual(caught.exception.structured()["details"]["operation_id"], "receipt")

    def test_lock_wait_is_bounded_and_does_not_send(self):
        transport, server = self.live()
        transport._lock.acquire()
        try:
            with self.assertRaises(HorizontalError) as caught: transport.call(self.request())
            self.assertEqual(caught.exception.structured()["outcome"], "not_sent")
            self.assertFalse(transport.closed)
        finally: transport._lock.release()

    def test_mismatched_response_invalidates_connection(self):
        transport, server = self.live()
        server.sendall(b'{"jsonrpc":"2.0","id":99,"result":{}}\n')
        with self.assertRaises(HorizontalError): transport.call(self.request())
        self.assertTrue(transport.closed)

    def test_subprocess_hang_is_killed_within_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "worker"
            path.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(10)\n")
            path.chmod(0o700)
            transport = SubprocessTransport(path, timeout=.1)
            start = time.monotonic()
            with self.assertRaises(HorizontalError): transport.call(self.request())
            self.assertLess(time.monotonic() - start, 1)
            self.assertIsNotNone(transport._process.poll())

    def test_mutation_is_never_automatically_replayed(self):
        class Broken(Transport):
            count = 0
            def call(self, request):
                self.count += 1
                raise transport_error("CONNECTION_LOST", "Lost receipt", request, "indeterminate")
        transport = Broken(); session = Session(transport=transport); session.engine = {"api": 2}
        project = Project(session, {"handle": 1, "path": "/tmp/test", "title": "Test", "revision": "r1"})
        with patch.object(session, "reconnect") as reconnect:
            with self.assertRaises(HorizontalError): project.apply([{"op": "ensure_net", "name": "x"}])
            reconnect.assert_not_called()
        self.assertEqual(transport.count, 1)

    def test_live_read_rebinds_only_the_same_document_instance(self):
        summary = {"handle": 1, "path": "/tmp/project.horizontal", "title": "Test", "revision": "r1", "instance_id": "document-1", "live": True}
        for returned_instance in ("document-1", "document-2"):
            class ScriptedLive(LiveTransport):
                def __init__(self, broken=False): self.broken = broken; self.closed = False; self.calls = []
                def close(self): self.closed = True
                def call(self, request):
                    self.calls.append(request["method"])
                    if self.broken: raise transport_error("CONNECTION_LOST", "Disconnected", request)
                    if request["method"] == "version": value = {"api": 2}
                    elif request["method"] == "list_projects": value = [{**summary, "handle": 9, "instance_id": returned_instance}]
                    else:
                        self_handle = request["params"]["handle"]
                        if self_handle != 9: raise AssertionError("Stale handle was reused")
                        value = {"data": [{"id": "net-1"}], "meta": {"source": "live", "revision": "r2"}}
                    return {"jsonrpc": "2.0", "id": request["id"], "result": value}
            session = Session(transport=ScriptedLive(broken=True)); session.engine = {"api": 2}
            project = Project(session, dict(summary)); replacement = ScriptedLive()
            with patch("horizontal.client.find_live", return_value={"port": 1, "token": "rotated"}), patch("horizontal.client.LiveTransport", return_value=replacement), patch("horizontal.client.default_transport") as disk:
                # is_live inspects the actual class, so reconnect itself is exercised
                # using a session subclass whose transport identity stays explicit.
                with patch.object(Session, "is_live", new=property(lambda self: True)):
                    if returned_instance == "document-1":
                        self.assertEqual(project.nets(), [{"id": "net-1"}])
                        self.assertEqual(project.last_metadata["source"], "live")
                    else:
                        with self.assertRaises(HorizontalError) as caught: project.nets()
                        self.assertEqual(caught.exception.structured()["code"], "LIVE_DOCUMENT_CHANGED")
                disk.assert_not_called()
            self.assertEqual(session.generation, 1)

    def test_explicit_disk_does_not_attempt_live_discovery(self):
        class Disk(Transport):
            def call(self, request):
                value = {"api": 2} if request["method"] == "version" else {"handle": 1, "path": "/tmp/test", "revision": "r1", "live": False}
                return {"jsonrpc": "2.0", "id": request["id"], "result": value}
        with patch("horizontal.client.default_transport", return_value=Disk()), patch("horizontal.client.Session.live") as live:
            project = open_project("/tmp/test", source="disk")
            self.assertFalse(project.is_live)
            live.assert_not_called()

    def test_incompatible_engine_stays_rejected_after_first_error(self):
        class Old(Transport):
            def call(self, request):
                self.assert_version = request["method"] == "version"
                if not self.assert_version: raise AssertionError("Incompatible engine received a design request")
                return {"jsonrpc": "2.0", "id": request["id"], "result": {"api": 1}}
        session = Session(transport=Old())
        for _ in range(2):
            with self.assertRaises(HorizontalError) as caught: session.call("list_projects")
            self.assertEqual(caught.exception.structured()["code"], "INCOMPATIBLE_ENGINE")


class HolderDiscoveryTests(unittest.TestCase):
    """The app's discovery file is inside its sandbox container, which macOS
    refuses other processes. The records beside a project are the way through."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / "Test.horizontal"
        self.project.mkdir()

    def hold(self, endpoint=None, pid=4242, project=None, locked=True):
        """A record beside the project, with its lock held as the app holds it."""
        import fcntl, os, uuid
        directory = Path(self.temp.name) / ".horizontal-transactions" / "digest" / "holders"
        directory.mkdir(parents=True, exist_ok=True)
        name = str(uuid.uuid4())
        lock = directory / f"{name}.lock"
        lock.write_bytes(b"")
        record = {"pid": pid, "name": "Horizontal", "since": "2026-09-08T00:00:00Z",
                  "project": str(project or self.project)}
        if endpoint is not None:
            record["endpoint"] = endpoint
        (directory / f"{name}.json").write_text(json.dumps(record))
        if not locked:
            return None
        descriptor = os.open(lock, os.O_RDWR)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(os.close, descriptor)
        return descriptor

    def test_only_locked_records_for_this_project_count(self):
        self.assertEqual(project_holders(self.project), [])
        self.hold(locked=False)
        self.assertEqual(project_holders(self.project), [], "a record nobody holds is a process that has exited")
        self.hold(project=Path(self.temp.name) / "Other.horizontal")
        self.assertEqual(project_holders(self.project), [], "a record for another project is not this one's")
        self.hold()
        holders = project_holders(self.project)
        self.assertEqual([h["name"] for h in holders], ["Horizontal"])
        self.assertNotIn("endpoint", holders[0])

    def test_a_published_endpoint_is_probed_before_it_is_believed(self):
        # Nothing listens on this port, so the record is not taken at its word.
        self.hold(endpoint={"host": "127.0.0.1", "port": "1", "token": "secret"})
        attempts = []
        with patch("horizontal._native.find_live", return_value=None):
            self.assertIsNone(find_live_for(self.project, attempts))
        self.assertTrue(any(a["status"] == "unreachable" for a in attempts), attempts)

        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.addCleanup(listener.close)
        self.hold(endpoint={"host": "127.0.0.1", "port": str(listener.getsockname()[1]), "token": "secret"})
        with patch("horizontal._native.find_live", return_value=None):
            found = find_live_for(self.project)
        self.assertEqual(found["token"], "secret")
        self.assertEqual(found["port"], listener.getsockname()[1], "a port written as text is still a port")

    def test_an_open_document_without_a_channel_says_so(self):
        self.hold()
        with patch("horizontal._native.find_live", return_value=None):
            with self.assertRaises(HorizontalError) as caught:
                open_project(self.project, source="live")
        message = caught.exception.structured()["message"]
        self.assertIn("Horizontal", message)
        self.assertIn("live channel", message)


if __name__ == "__main__": unittest.main()
