"""adb/scrcpy fallback: Session (control protocol, startup, close) and the adb_loop supervisor."""
import socket
import struct
import threading
import time
import unittest
from unittest import mock

from hubenv import HubTestCase, ferryd


class FakeState:
    def __init__(self):
        self.texts = []
        self.session = None

    def from_phone(self, text, sensitive=False):
        self.texts.append(text)


def msg_clipboard(text):
    raw = text.encode()
    return bytes([ferryd.DEV_CLIPBOARD]) + struct.pack(">I", len(raw)) + raw


class SessionCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.fstate = FakeState()
        self.jar = self.root / "scrcpy-server"
        self.jar.write_bytes(b"x" * 1234)
        self.session = ferryd.Session(self.fstate, "SER1", str(self.jar), "3.3.1")
        self.addCleanup(self.session.close)

    def attach_socket(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        self.session.sock = a
        return b

    def wait_for(self, cond, what, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return
            time.sleep(0.01)
        self.fail(f"timed out waiting for {what}")


class Reader(SessionCase):
    def run_reader(self, payload, close=True):
        peer = self.attach_socket()
        peer.sendall(payload)
        if close:
            peer.close()
        t = threading.Thread(target=self.session._reader, daemon=True)
        t.start()
        t.join(3)
        self.assertFalse(t.is_alive(), "reader did not stop")

    def test_clipboard_messages_reach_state(self):
        self.run_reader(msg_clipboard("one") + msg_clipboard("日本語"))
        self.assertEqual(self.fstate.texts, ["one", "日本語"])
        self.assertTrue(self.session.dead.is_set())

    def test_ack_and_uhid_messages_are_skipped_without_losing_sync(self):
        ack = bytes([ferryd.DEV_ACK_CLIPBOARD]) + b"\x00" * 8
        uhid = bytes([ferryd.DEV_UHID_OUTPUT]) + struct.pack(">HH", 7, 3) + b"abc"
        self.run_reader(ack + uhid + msg_clipboard("after"))
        self.assertEqual(self.fstate.texts, ["after"])

    def test_unknown_message_type_ends_the_session(self):
        self.run_reader(b"\x7f" + msg_clipboard("never"))
        self.assertEqual(self.fstate.texts, [])
        self.assertTrue(self.session.dead.is_set())
        self.assertIn("unknown device message type 127", self.log_text())

    def test_invalid_utf8_is_replaced(self):
        self.run_reader(bytes([ferryd.DEV_CLIPBOARD]) + struct.pack(">I", 3) + b"a\xffb")
        self.assertEqual(self.fstate.texts, ["a�b"])

    def test_empty_clipboard_message(self):
        self.run_reader(msg_clipboard(""))
        self.assertEqual(self.fstate.texts, [""])

    def test_truncated_message_marks_dead_and_logs(self):
        self.run_reader(bytes([ferryd.DEV_CLIPBOARD]) + struct.pack(">I", 10) + b"abc")
        self.assertTrue(self.session.dead.is_set())
        self.assertIn("control socket closed", self.log_text())

    def test_closing_on_purpose_is_not_logged_as_an_error(self):
        peer = self.attach_socket()
        self.session.closing = True
        peer.close()
        self.session._reader()
        self.assertNotIn("control socket closed", self.log_text())
        self.assertTrue(self.session.dead.is_set())

    def test_split_message_is_reassembled(self):
        peer = self.attach_socket()
        t = threading.Thread(target=self.session._reader, daemon=True)
        t.start()
        data = msg_clipboard("split me")
        for i in range(len(data)):
            peer.sendall(data[i:i + 1])
        self.wait_for(lambda: self.fstate.texts == ["split me"], "text")
        peer.close()
        t.join(3)


class SendClipboard(SessionCase):
    def test_wire_layout(self):
        peer = self.attach_socket()
        self.session.send_clipboard("héllo")
        raw = "héllo".encode()
        expected = struct.pack(">BQBI", ferryd.CTRL_SET_CLIPBOARD, 0, 0, len(raw)) + raw
        peer.settimeout(2)
        self.assertEqual(peer.recv(100), expected)

    def test_text_over_the_limit_is_skipped_and_logged(self):
        peer = self.attach_socket()
        self.session.send_clipboard("x" * (ferryd.MAX_TEXT + 1))
        peer.settimeout(0.2)
        with self.assertRaises(socket.timeout):
            peer.recv(1)
        self.assertIn("too large to sync", self.log_text())

    def test_text_at_the_limit_is_sent(self):
        peer = self.attach_socket()
        t = threading.Thread(target=self.session.send_clipboard, args=("x" * ferryd.MAX_TEXT,))
        t.start()
        peer.settimeout(3)
        got = b""
        want = 14 + ferryd.MAX_TEXT
        while len(got) < want:
            got += peer.recv(65536)
        t.join()
        self.assertEqual(len(got), want)

    def test_limit_counts_bytes_not_characters(self):
        peer = self.attach_socket()
        self.session.send_clipboard("あ" * (ferryd.MAX_TEXT // 3 + 1))
        peer.settimeout(0.2)
        with self.assertRaises(socket.timeout):
            peer.recv(1)


class Close(SessionCase):
    def test_close_is_safe_on_a_fresh_session(self):
        self.session.close()
        self.assertTrue(self.session.closing)

    def test_close_closes_socket_terminates_server_and_removes_the_forward(self):
        sock = mock.MagicMock()
        proc = mock.MagicMock()
        proc.poll.return_value = None
        self.session.sock, self.session.proc, self.session.port = sock, proc, 40123
        self.session.close()
        sock.close.assert_called_once()
        proc.terminate.assert_called_once()
        proc.kill.assert_not_called()
        self.assertIn("adb -s SER1 forward --remove tcp:40123", self.call_log())

    def test_unresponsive_server_is_killed(self):
        import subprocess
        proc = mock.MagicMock()
        proc.poll.return_value = None
        proc.wait.side_effect = subprocess.TimeoutExpired("adb", 3)
        self.session.proc = proc
        self.session.close()
        proc.kill.assert_called_once()

    def test_already_exited_server_is_left_alone(self):
        proc = mock.MagicMock()
        proc.poll.return_value = 0
        self.session.proc = proc
        self.session.close()
        proc.terminate.assert_not_called()

    def test_socket_close_errors_are_ignored(self):
        sock = mock.MagicMock()
        sock.close.side_effect = OSError("bad")
        self.session.sock = sock
        self.session.close()

    def test_without_a_forward_nothing_is_removed(self):
        self.session.close()
        self.assertNotIn("forward --remove", self.call_log())


class PipeServerLog(SessionCase):
    def test_lines_are_logged_with_a_prefix_and_blank_lines_dropped(self):
        self.session.proc = mock.MagicMock()
        self.session.proc.stdout = [b"WARN something\n", b"\n", b"  \r\n", b"\xff bad bytes\n"]
        self.session._pipe_server_log()
        text = self.log_text()
        self.assertIn("[phone] WARN something", text)
        self.assertIn("[phone] � bad bytes", text)
        self.assertEqual(text.count("[phone]"), 2)
        self.assertTrue(self.session.dead.is_set())


class Start(SessionCase):
    def server(self, send=b"\x00", hold=True):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(2)
        self.addCleanup(srv.close)
        conns = []

        def serve():
            while True:
                try:
                    c, _ = srv.accept()
                except OSError:
                    return
                conns.append(c)
                if send:
                    c.sendall(send)

        threading.Thread(target=serve, daemon=True).start()
        self.addCleanup(lambda: [c.close() for c in conns])
        port = srv.getsockname()[1]
        self.set_state("adb_out_forward", f"{port}\n")
        return conns

    def test_pushes_the_server_when_the_device_copy_differs(self):
        self.server()
        self.set_state("device_jar_size", "99")
        self.session.start()
        self.assertIn(f"adb -s SER1 push {self.jar} {ferryd.DEVICE_JAR}", self.call_log())

    def test_skips_the_push_when_sizes_match(self):
        self.server()
        self.set_state("device_jar_size", "1234")
        self.session.start()
        self.assertNotIn(" push ", self.call_log())

    def test_push_failure_is_an_error(self):
        self.set_state("adb_fail_push", "adb: error: no space\n")
        with self.assertRaisesRegex(RuntimeError, "push failed: adb: error: no space"):
            self.session.start()

    def test_forward_failure_is_an_error(self):
        self.set_state("device_jar_size", "1234")
        self.set_state("adb_fail_forward", "error: closed\n")
        with self.assertRaisesRegex(RuntimeError, "adb forward failed"):
            self.session.start()

    def test_launches_the_scrcpy_server_with_clipboard_only_options(self):
        self.server()
        self.set_state("device_jar_size", "1234")
        launched = []
        real_popen = ferryd.subprocess.Popen

        def popen(args, *a, **k):
            if "shell" in args and "app_process" in args[-1]:
                launched.append(args)
                return real_popen(args, *a, **k)
            return real_popen(args, *a, **k)

        with mock.patch.object(ferryd.subprocess, "Popen", popen):
            self.session.start()
        self.track(self.session.proc)
        cmd = launched[0]
        self.assertEqual(cmd[:4], ["adb", "-s", "SER1", "shell"])
        for opt in ("video=false", "audio=false", "control=true", "clipboard_autosync=true", "power_on=false",
                    "cleanup=false", "tunnel_forward=true", "3.3.1"):
            self.assertIn(opt, cmd[4])
        self.assertIn(f"CLASSPATH={ferryd.DEVICE_JAR}", cmd[4])

    def test_forward_uses_a_random_abstract_socket_name(self):
        self.server()
        self.set_state("device_jar_size", "1234")
        self.session.start()
        self.assertRegex(self.call_log(), r"forward tcp:0 localabstract:scrcpy_[0-9a-f]{8}")

    def test_connects_waits_for_the_dummy_byte_and_forwards_messages(self):
        conns = self.server(send=b"\x00" + msg_clipboard("from device"))
        self.set_state("device_jar_size", "1234")
        self.session.start()
        self.track(self.session.proc)
        self.wait_for(lambda: self.fstate.texts == ["from device"], "clipboard message")
        self.assertIsNotNone(self.session.sock)
        self.assertFalse(self.session.dead.is_set())

    def test_working_session_can_send_clipboard_to_the_device(self):
        conns = self.server()
        self.set_state("device_jar_size", "1234")
        self.session.start()
        self.track(self.session.proc)
        self.wait_for(lambda: conns, "server side")
        self.session.send_clipboard("to device")
        conns[0].settimeout(2)
        got = conns[0].recv(100)
        self.assertTrue(got.endswith(b"to device"))
        self.assertEqual(got[0], ferryd.CTRL_SET_CLIPBOARD)

    def test_server_exiting_during_startup_is_an_error(self):
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        port = closed.getsockname()[1]
        closed.close()
        self.set_state("adb_out_forward", f"{port}\n")
        self.set_state("device_jar_size", "1234")
        self.set_state("server_exit", "1")
        with mock.patch.object(ferryd.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "server exited during startup"):
                self.session.start()

    def test_connection_without_the_dummy_byte_times_out(self):
        self.server(send=b"")
        self.set_state("device_jar_size", "1234")
        clock = iter([100.0] + [100.0, 200.0] * 50)
        with mock.patch.object(ferryd.time, "time", lambda: next(clock)), mock.patch.object(ferryd.time, "sleep"):
            with mock.patch.object(ferryd.socket, "create_connection", side_effect=lambda *a, **k: _silent_sock()):
                with self.assertRaisesRegex(RuntimeError, "timed out waiting for server"):
                    self.session.start()
        self.track(self.session.proc)

    def test_a_non_numeric_forward_port_raises_value_error(self):
        # Pinned: adb_loop only catches OSError and RuntimeError.
        self.set_state("device_jar_size", "1234")
        self.set_state("adb_out_forward", "garbage\n")
        with self.assertRaises(ValueError):
            self.session.start()


def _silent_sock():
    a, b = socket.socketpair()
    b.close()
    a.settimeout(0.01)
    s = mock.MagicMock()
    s.recv.return_value = b"\x01"
    return s


class StopLoop(Exception):
    pass


class AdbLoop(HubTestCase):
    def run_loop(self, link, steps, ensure=None, session_factory=None, state=None):
        state = state or FakeState()
        sleeps = []

        def sleep(s):
            sleeps.append(s)
            if len(sleeps) >= steps:
                raise StopLoop

        patches = [mock.patch.object(ferryd.time, "sleep", sleep)]
        if ensure is not None:
            patches.append(mock.patch.object(ferryd, "ensure_connected", ensure))
        if session_factory is not None:
            patches.append(mock.patch.object(ferryd, "Session", session_factory))
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        with self.assertRaises(StopLoop):
            ferryd.adb_loop(state, link, "/srv", "1.0")
        return state, sleeps

    class Link:
        def __init__(self, connected):
            self.connected = connected

    def test_first_sleep_gives_the_app_time_to_reconnect(self):
        _, sleeps = self.run_loop(self.Link(True), 1)
        self.assertEqual(sleeps, [8])

    def test_does_nothing_while_the_app_is_connected(self):
        ensure = mock.MagicMock()
        _, sleeps = self.run_loop(self.Link(True), 4, ensure=ensure)
        ensure.assert_not_called()
        self.assertEqual(sleeps, [8, 1, 1, 1])

    def test_backoff_doubles_up_to_thirty_seconds_and_logs_once(self):
        _, sleeps = self.run_loop(self.Link(False), 9, ensure=lambda: None)
        self.assertEqual(sleeps, [8, 2, 4, 8, 16, 30, 30, 30, 30])
        self.assertEqual(self.log_text().count("adb: phone not reachable"), 1)

    def test_a_working_session_runs_until_the_app_connects(self):
        link = self.Link(False)
        events = []

        class S:
            def __init__(self, state, serial, server, version):
                self.dead = threading.Event()
                events.append(("new", serial, server, version))

            def start(self):
                events.append("start")

            def close(self):
                events.append("close")

        orig_wait = threading.Event.wait

        def connect_soon(ev_self, t=None):
            link.connected = True
            return False

        with mock.patch.object(threading.Event, "wait", connect_soon):
            state, _ = self.run_loop(link, 2, ensure=lambda: "SER9", session_factory=S)
        self.assertEqual(events, [("new", "SER9", "/srv", "1.0"), "start", "close"])
        self.assertIsNone(state.session)
        self.assertIn("adb: syncing with SER9", self.log_text())
        self.assertIn("Ferry app connected; closing adb session", self.log_text())

    def test_session_start_errors_are_logged_and_the_loop_continues(self):
        events = []

        class S:
            def __init__(self, *a):
                self.dead = threading.Event()

            def start(self):
                raise RuntimeError("server exited during startup")

            def close(self):
                events.append("close")

        state, sleeps = self.run_loop(self.Link(False), 3, ensure=lambda: "SER9", session_factory=S)
        self.assertIn("adb: session error: server exited during startup", self.log_text())
        self.assertEqual(events, ["close", "close"])
        self.assertIsNone(state.session)
        self.assertEqual(sleeps[1], 2)

    def test_dead_session_is_replaced(self):
        made = []

        class S:
            def __init__(self, *a):
                self.dead = threading.Event()
                self.dead.set()
                made.append(self)

            def start(self):
                pass

            def close(self):
                pass

        self.run_loop(self.Link(False), 4, ensure=lambda: "SER9", session_factory=S)
        self.assertGreaterEqual(len(made), 2)


if __name__ == "__main__":
    unittest.main()
