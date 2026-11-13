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
                                find_live, find_live_for, live_endpoints, project_holders, transport_error)
from horizontal.client import Session, Project, live_holders, open as open_project, project_file


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
        # 155: what didn't answer, how long it was given, and what happens next.
        self.assertIn("did not answer apply within", caught.exception.message)
        self.assertIn("next call on this context reconnects", caught.exception.message)

    def test_a_session_remembers_what_closed_its_connection(self):
        transport, server = self.live()
        session = Session(transport=transport)
        session.engine = {"api": 2}
        with self.assertRaises(HorizontalError): session.call("get_pool_item", uuid="x")
        self.assertEqual(session.last_transport_error["code"], "TIMEOUT")
        self.assertEqual(session.last_transport_error["method"], "get_pool_item")

    def test_lock_wait_is_bounded_and_does_not_send(self):
        transport, server = self.live()
        transport._lock.acquire()
        try:
            with self.assertRaises(HorizontalError) as caught: transport.call(self.request())
            self.assertEqual(caught.exception.structured()["outcome"], "not_sent")
            self.assertFalse(transport.closed)
        finally: transport._lock.release()

    def test_alive_sees_the_app_go_without_sending(self):
        # 78: a quit app closes its end; the connection is only marked closed
        # once a call fails on it, so alive asks the socket.
        transport, server = self.live()
        self.assertTrue(transport.alive())
        server.close()
        self.assertFalse(transport.alive())
        self.assertFalse(transport.closed, "alive sends nothing and closes nothing")

    def test_alive_does_not_eat_a_pending_reply_or_wait_on_a_call(self):
        transport, server = self.live()
        server.sendall(b'{"jsonrpc":"2.0","id":7,"result":{}}\n')
        self.assertTrue(transport.alive())
        self.assertEqual(transport._socket.recv(1, socket.MSG_PEEK), b"{", "the byte it looked at is still there")
        transport._lock.acquire()
        try:
            self.assertTrue(transport.alive(), "a call in progress means the connection is in use")
        finally:
            transport._lock.release()

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
            def __init__(self): self.methods = []
            def call(self, request):
                self.methods.append(request["method"])
                raise transport_error("CONNECTION_LOST", "Lost receipt", request, "indeterminate")
        transport = Broken(); session = Session(transport=transport); session.engine = {"api": 2}
        project = Project(session, {"handle": 1, "path": "/tmp/test", "title": "Test", "revision": "r1"})
        with patch.object(session, "reconnect"), patch.object(project, "_rebind"):
            with self.assertRaises(HorizontalError) as caught: project.apply([{"op": "ensure_net", "name": "x"}])
        # The outcome is looked up, never resent.
        self.assertEqual(transport.methods, ["apply", "transaction_status"])
        self.assertEqual(caught.exception.structured()["outcome"], "unknown")

    def test_lost_mutation_is_resolved_from_its_receipt(self):
        for state, outcome in (("committed", None), ("not_committed", "not_committed"), ("unknown", "not_committed")):
            class Scripted(Transport):
                def __init__(self): self.methods = []
                def call(self, request):
                    self.methods.append(request["method"])
                    if request["method"] == "apply":
                        raise transport_error("TIMEOUT", "Timed out", request, "indeterminate")
                    receipt = {"operation_id": request["params"]["operation_id"], "status": state, "error": "No component X."}
                    return {"jsonrpc": "2.0", "id": request["id"], "result": receipt}
            transport = Scripted(); session = Session(transport=transport); session.engine = {"api": 2}
            project = Project(session, {"handle": 1, "path": "/tmp/test", "title": "Test", "revision": "r1"})
            with patch.object(session, "reconnect"), patch.object(project, "_rebind"):
                if outcome is None:
                    self.assertEqual(project.apply([{"op": "ensure_net", "name": "x"}])["status"], "committed")
                else:
                    with self.assertRaises(HorizontalError) as caught: project.apply([{"op": "ensure_net", "name": "x"}])
                    self.assertEqual(caught.exception.structured()["outcome"], outcome, state)
            self.assertEqual(transport.methods, ["apply", "transaction_status"], state)

    def test_a_closed_connection_is_reopened_before_sending(self):
        class Fine(Transport):
            def call(self, request):
                return {"jsonrpc": "2.0", "id": request["id"], "result": {"data": [], "meta": {"source": "live", "revision": "r2"}}}
        session = Session(transport=Fine()); session.engine = {"api": 2}
        session.transport.closed = True
        project = Project(session, {"handle": 1, "path": "/tmp/test", "title": "Test", "revision": "r1"})
        def reopen(timeout):
            session.transport = Fine()
            session.generation += 1
        with patch.object(session, "reconnect", side_effect=reopen) as reconnect, patch.object(project, "_rebind"):
            project.nets()
            reconnect.assert_called_once()

    def test_reconnect_looks_beside_the_project(self):
        session = Session(transport=Transport(), project="/tmp/p.hprj")
        with patch.object(Session, "is_live", new=property(lambda self: True)), \
             patch("horizontal.client.find_live_for", return_value={"port": 1, "token": "t"}) as beside, \
             patch("horizontal.client.find_live", return_value=None), \
             patch("horizontal.client.LiveTransport") as live:
            session.reconnect(1)
        beside.assert_called_once_with("/tmp/p.hprj")
        live.assert_called_once()

    def test_reconnect_returns_to_the_channel_it_was_on(self):
        # With more than one channel up, the first found need not be the app that has the document.
        class Was(Transport):
            info = {"port": 2, "token": "b"}
        session = Session(transport=Was(), project="/tmp/p.horizontal")
        endpoints = [{"port": 1, "token": "a"}, {"port": 2, "token": "b"}]
        with patch.object(Session, "is_live", new=property(lambda self: True)), \
             patch("horizontal.client.live_endpoints", return_value=iter(endpoints)), \
             patch("horizontal.client.find_live_for") as first, \
             patch("horizontal.client.LiveTransport") as live:
            session.reconnect(1)
        self.assertEqual(live.call_args.args[0], endpoints[1])
        first.assert_not_called()

    def test_mutations_get_a_longer_budget_than_reads(self):
        seen = {}
        class Clock(Transport):
            def call(self, request):
                seen[request["method"]] = request["deadline_unix_ms"] / 1000 - time.time()
                return {"jsonrpc": "2.0", "id": request["id"], "result": {"applied": 0, "changes": []}}
        session = Session(transport=Clock()); session.engine = {"api": 2}
        project = Project(session, {"handle": 1, "path": "/tmp/test", "title": "Test", "revision": "r1"})
        with patch.dict("os.environ", {"HORIZONTAL_MUTATION_TIMEOUT": "120"}):
            project.apply([{"op": "ensure_net", "name": "x"}])
            project._call("list_nets")
        self.assertGreater(seen["apply"], 100)
        self.assertLess(seen["list_nets"], 31)

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
    """An app from before it published in its cache folder keeps its discovery
    file inside its sandbox container, which macOS refuses other processes. The
    records beside a project are the way through to that one."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / "Test.horizontal"
        self.project.mkdir()
        # No discovery files: these are about the records, and an app running
        # on this machine is not part of them.
        files = patch("horizontal._native.live_discovery_paths", return_value=[])
        files.start()
        self.addCleanup(files.stop)

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


class FakeApp:
    """A loopback listener that answers as the app's live channel does, for the documents it is given."""

    def __init__(self, documents=(), token="secret"):
        self.documents = [Path(d) for d in documents]
        self.token = token
        self.asked: list[str] = []
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.answer, args=(connection,), daemon=True).start()

    def answer(self, connection):
        with connection, connection.makefile("rwb") as stream:
            for line in stream:
                request = json.loads(line)
                self.asked.append(request["method"])
                if request.get("auth") != self.token:
                    reply = {"error": {"code": -32008, "message": "Unauthorized"}}
                elif request["method"] == "version":
                    reply = {"result": {"api": 2}}
                elif request["method"] == "list_projects":
                    reply = {"result": [{"handle": number, "path": str(document), "title": document.stem,
                                         "revision": "r1", "live": True}
                                        for number, document in enumerate(self.documents, 1)]}
                else:
                    reply = {"result": None}
                stream.write((json.dumps({"jsonrpc": "2.0", "id": request["id"], **reply}) + "\n").encode())
                stream.flush()

    def close(self):
        self.listener.close()


class SharedDiscoveryTests(unittest.TestCase):
    """A sandboxed app with a .horizontal package open can write no holder record beside it, and its container
    is closed to other processes. Its per-user cache folder is not, and each process publishes a file of its
    own there."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.shared = root / "com.twarge.app.horizontal"
        self.shared.mkdir()
        self.project = root / "Test.horizontal"
        self.project.mkdir()
        (self.project / "Test.hprj").write_text("{}")
        # Only this folder: not an app running on this machine, nor its container.
        for started in (patch("horizontal._native.shared_discovery_directory", return_value=self.shared),
                        patch.object(Path, "home", return_value=root / "home"),
                        patch.dict("os.environ")):
            started.start()
            self.addCleanup(started.stop)
        import os
        os.environ.pop("HORIZONTAL_LIVE", None)
        self.written = time.time() - 100

    def app(self, documents=(), token="secret"):
        app = FakeApp(documents, token)
        self.addCleanup(app.close)
        return app

    def publish(self, port, token="secret", pid=None):
        """A process's file in the folder, each newer than the one before."""
        import os
        pid = os.getpid() if pid is None else pid
        path = self.shared / f"live-{pid}-{port}.json"
        path.write_text(json.dumps({"version": 2, "host": "127.0.0.1", "port": port, "token": token, "pid": pid}))
        self.written += 1
        os.utime(path, (self.written, self.written))
        return path

    def test_a_file_in_the_cache_folder_is_found_without_a_project(self):
        self.assertIsNone(find_live())
        app = self.app()
        path = self.publish(app.port)
        found = find_live()
        self.assertEqual((found["port"], found["token"], found["path"]), (app.port, "secret", str(path)))
        self.assertEqual([info["port"] for info in live_endpoints()], [app.port])
        self.assertEqual(find_live_for(self.project)["port"], app.port, "and with one")

    def test_every_channel_that_answers_is_offered_newest_first_and_once(self):
        older, newer = self.app(), self.app()
        self.publish(older.port)
        self.publish(newer.port)
        self.publish(newer.port, pid=1)  # The same channel named twice is one channel.
        self.assertEqual([info["port"] for info in live_endpoints(self.project)], [newer.port, older.port])

    def test_open_takes_the_channel_that_has_the_document(self):
        # The newest file is another copy of the app, with another document open.
        mine = self.app([self.project])
        other = self.app([self.project.parent / "Other.horizontal"], token="theirs")
        self.publish(mine.port)
        self.publish(other.port, token="theirs")

        project = open_project(self.project, source="live")
        self.addCleanup(project.session.close)
        self.assertTrue(project.is_live)
        self.assertEqual(project.session.transport.info["port"], mine.port)
        self.assertIn("list_projects", other.asked, "the first was asked, and did not have it")

        # A package is known by the package, so its .hprj finds the same document.
        inside = open_project(self.project / "Test.hprj", source="live")
        self.addCleanup(inside.session.close)
        self.assertEqual(Path(inside.path), self.project)

    def test_a_channel_without_the_document_is_not_the_document(self):
        other = self.app([self.project.parent / "Other.horizontal"])
        self.publish(other.port)
        with self.assertRaises(HorizontalError) as caught:
            open_project(self.project, source="live")
        self.assertEqual(caught.exception.structured()["code"], "LIVE_UNAVAILABLE")

    def test_a_crashed_apps_file_is_cleared_and_a_running_ones_is_kept(self):
        import subprocess
        gone = subprocess.Popen([sys.executable, "-c", "pass"])
        gone.wait()
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        port = closed.getsockname()[1]
        closed.close()

        crashed = self.publish(port, pid=gone.pid)
        starting = self.publish(port)  # This process's: it is running, and may yet listen.
        attempts = []
        self.assertIsNone(find_live(attempts))
        self.assertFalse(crashed.exists(), "nothing will listen there again")
        self.assertTrue(starting.exists())
        self.assertEqual({attempt["status"] for attempt in attempts if attempt["path"].startswith(str(self.shared))},
                         {"unreachable"})

    def test_a_package_is_known_by_the_package(self):
        self.assertEqual(project_file(self.project), self.project)
        self.assertEqual(project_file(self.project / "Test.hprj"), self.project,
                         "what the app has open, and what its transaction directory is named for")
        folder = self.project.parent / "Folder"
        folder.mkdir()
        (folder / "Folder.hprj").write_text("{}")
        self.assertEqual(project_file(folder / "Folder.hprj"), folder / "Folder.hprj", "a Horizon project is its .hprj")
        self.assertEqual(project_file(folder), folder / "Folder.hprj")

    def test_a_live_channel_that_lists_the_project_holds_it(self):
        # No record can say so for a sandboxed app's package, so the channel does.
        self.assertEqual(live_holders(self.project), [])
        other = self.app([self.project.parent / "Other.horizontal"])
        self.publish(other.port)
        self.assertEqual(live_holders(self.project), [])

        mine = self.app([self.project], token="mine")
        self.publish(mine.port, token="mine")
        holders = live_holders(self.project / "Test.hprj")
        self.assertEqual([(holder["name"], holder["project"]) for holder in holders], [("Horizontal", str(self.project))])
        self.assertNotIn("mine", json.dumps(holders), "the token stays where it was read")

    def test_a_disk_edit_is_refused_while_a_live_channel_lists_the_project(self):
        from horizontal import mcp_server
        disk = Project(Session(transport=Transport()),
                       {"handle": 1, "path": str(self.project), "title": "Test", "revision": "r1", "live": False})
        self.assertEqual(mcp_server._guard(disk, dry_run=True), {})

        mine = self.app([self.project])
        self.publish(mine.port)
        with self.assertRaises(HorizontalError) as caught:
            mcp_server._guard(disk, dry_run=True)
        error = caught.exception.structured()
        self.assertEqual(error["code"], "DOCUMENT_OPEN")
        self.assertIn('source="live"', error["message"])


if __name__ == "__main__": unittest.main()
