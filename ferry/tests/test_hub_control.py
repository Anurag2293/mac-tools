"""Control socket (ferry shot/status), launchd install/uninstall/status, and subcommand dispatch."""
import contextlib
import io
import os
import plistlib
import socket
import stat
import sys
import threading
import time
import unittest
from unittest import mock

from hubenv import HubTestCase, ferryd


class StubLink:
    def __init__(self, connected=True, model="Pixel 7 Pro", shot=(b"PNG", None), delay=0):
        self._connected = connected
        self.model = model
        self.shot = shot
        self.delay = delay
        self.shots = 0

    @property
    def connected(self):
        return self._connected

    def screenshot(self, timeout=15):
        self.shots += 1
        time.sleep(self.delay)
        return self.shot


class ControlCase(HubTestCase):
    def serve(self, link):
        ferryd.serve_control(link)
        return str(ferryd.CTL_SOCK)

    def ask(self, path, payload, read_all=True, timeout=5):
        c = socket.socket(socket.AF_UNIX)
        c.settimeout(timeout)
        c.connect(path)
        self.addCleanup(c.close)
        if payload is not None:
            c.sendall(payload)
        if not read_all:
            return c
        chunks = []
        while True:
            d = c.recv(65536)
            if not d:
                break
            chunks.append(d)
        return b"".join(chunks)


class ServeControl(ControlCase):
    def test_creates_the_socket_privately_and_creates_the_directory(self):
        ferryd.LINK_DIR.rmdir()
        path = self.serve(StubLink())
        self.assertTrue(stat.S_ISSOCK(os.stat(path).st_mode))
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_replaces_a_stale_socket_file(self):
        ferryd.CTL_SOCK.write_text("stale")
        path = self.serve(StubLink())
        self.assertEqual(self.ask(path, b"status\n"), b"ok connected Pixel 7 Pro\n")

    def test_status_connected_and_disconnected(self):
        path = self.serve(StubLink(connected=True, model="Pixel 9"))
        self.assertEqual(self.ask(path, b"status\n"), b"ok connected Pixel 9\n")

    def test_status_when_no_phone(self):
        path = self.serve(StubLink(connected=False))
        self.assertEqual(self.ask(path, b"status\n"), b"ok disconnected\n")

    def test_shot_returns_length_line_then_png(self):
        png = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 10
        path = self.serve(StubLink(shot=(png, None)))
        reply = self.ask(path, b"shot\n")
        head, _, body = reply.partition(b"\n")
        self.assertEqual(head, f"ok {len(png)}".encode())
        self.assertEqual(body, png)

    def test_shot_large_png_arrives_intact(self):
        png = os.urandom(3 << 20)
        path = self.serve(StubLink(shot=(png, None)))
        reply = self.ask(path, b"shot\n")
        head, _, body = reply.partition(b"\n")
        self.assertEqual(int(head.split()[1]), len(png))
        self.assertEqual(body, png)

    def test_shot_error_is_reported_on_one_line(self):
        path = self.serve(StubLink(shot=(None, "phone app not connected")))
        self.assertEqual(self.ask(path, b"shot\n"), b"err phone app not connected\n")

    def test_shot_with_empty_png_and_no_error_says_err_none(self):
        # Pinned: an empty capture without an error message is reported as "err None".
        path = self.serve(StubLink(shot=(b"", None)))
        self.assertEqual(self.ask(path, b"shot\n"), b"err None\n")

    def test_commands_work_without_a_trailing_newline_and_with_whitespace(self):
        path = self.serve(StubLink())
        self.assertTrue(self.ask(path, b"status").startswith(b"ok connected"))
        self.assertTrue(self.ask(path, b"  status \r\n").startswith(b"ok connected"))

    def test_unknown_commands(self):
        path = self.serve(StubLink())
        for payload in (b"bogus\n", b"\n", b"SHOT\n", b"Status\n", b"status extra\n", b"shot;status\n",
                        b"\xff\xfe\n", b"x" * 500, b"shot\x00\n"):
            with self.subTest(payload=payload[:20]):
                self.assertEqual(self.ask(path, payload), b"err unknown command\n")

    def test_only_the_first_64_bytes_are_considered(self):
        path = self.serve(StubLink())
        self.assertTrue(self.ask(path, b"status" + b" " * 200).startswith(b"ok connected"))

    def test_client_that_disconnects_without_a_command_does_not_break_the_server(self):
        path = self.serve(StubLink())
        c = socket.socket(socket.AF_UNIX)
        c.connect(path)
        c.close()
        time.sleep(0.1)
        self.assertTrue(self.ask(path, b"status\n").startswith(b"ok"))

    def test_client_that_vanishes_during_a_slow_shot_does_not_break_the_server(self):
        path = self.serve(StubLink(delay=0.3))
        c = self.ask(path, b"shot\n", read_all=False)
        c.close()
        time.sleep(0.5)
        self.assertTrue(self.ask(path, b"status\n").startswith(b"ok"))

    def test_a_silent_client_does_not_block_others(self):
        path = self.serve(StubLink())
        silent = self.ask(path, None, read_all=False)
        self.assertTrue(self.ask(path, b"status\n").startswith(b"ok"))
        silent.close()

    def test_a_slow_shot_does_not_block_status(self):
        link = StubLink(delay=1.0)
        path = self.serve(link)
        slow = self.ask(path, b"shot\n", read_all=False)
        t0 = time.time()
        self.assertTrue(self.ask(path, b"status\n").startswith(b"ok"))
        self.assertLess(time.time() - t0, 0.8)
        slow.close()

    def test_many_concurrent_clients(self):
        path = self.serve(StubLink())
        results = []

        def go():
            results.append(self.ask(path, b"status\n"))

        threads = [threading.Thread(target=go) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(results), 4)
        self.assertTrue(all(r.startswith(b"ok connected") for r in results))

    def test_the_real_control_socket_path_is_never_used_by_tests(self):
        from hubenv import REAL_CTL_SOCK
        self.assertNotEqual(str(ferryd.CTL_SOCK), REAL_CTL_SOCK)
        with self.assertRaises(AssertionError):
            socket.socket(socket.AF_UNIX).connect(REAL_CTL_SOCK)


class Launchd(HubTestCase):
    def setUp(self):
        super().setUp()
        ferryd.PLIST.parent.mkdir(parents=True)
        p = mock.patch.object(ferryd.time, "sleep")
        self.sleep = p.start()
        self.addCleanup(p.stop)

    def run_capture(self, fn, *a):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            fn(*a)
        return out.getvalue()

    def launchctl_calls(self):
        return [l for l in self.call_log().splitlines() if l.startswith("launchctl")]

    def test_install_writes_a_valid_plist_and_loads_it(self):
        out = self.run_capture(ferryd.install)
        p = plistlib.loads(ferryd.PLIST.read_bytes())
        self.assertEqual(p["Label"], "com.anurag.ferry")
        self.assertEqual(p["ProgramArguments"][0], sys.executable)
        self.assertTrue(p["ProgramArguments"][1].endswith("hub/ferryd"))
        self.assertIs(p["RunAtLoad"], True)
        self.assertIs(p["KeepAlive"], True)
        self.assertEqual(p["ThrottleInterval"], 10)
        self.assertEqual(p["StandardOutPath"], str(ferryd.LOG))
        self.assertEqual(p["StandardErrorPath"], str(ferryd.LOG))
        uid = os.getuid()
        self.assertEqual(self.launchctl_calls(), [f"launchctl bootout gui/{uid}/com.anurag.ferry",
                                                  f"launchctl bootstrap gui/{uid} {ferryd.PLIST}"])
        self.assertIn(f"installed {ferryd.PLIST}", out)
        self.assertIn(f"log: {ferryd.LOG}", out)

    def test_install_retries_bootstrap_after_bootout(self):
        self.set_state("bootstrap_failures", "3")
        self.run_capture(ferryd.install)
        self.assertEqual(sum(l.startswith("launchctl bootstrap") for l in self.launchctl_calls()), 4)
        self.assertEqual(self.sleep.call_count, 3)

    def test_install_gives_up_after_ten_attempts(self):
        self.set_state("bootstrap_failures", "99")
        with self.assertRaises(SystemExit) as cm:
            self.run_capture(ferryd.install)
        self.assertIn("launchctl bootstrap failed", str(cm.exception))
        self.assertEqual(sum(l.startswith("launchctl bootstrap") for l in self.launchctl_calls()), 10)

    def test_install_succeeds_on_the_tenth_attempt(self):
        self.set_state("bootstrap_failures", "9")
        self.run_capture(ferryd.install)
        self.assertEqual(sum(l.startswith("launchctl bootstrap") for l in self.launchctl_calls()), 10)

    def test_uninstall_boots_out_and_removes_the_plist(self):
        ferryd.PLIST.write_text("x")
        out = self.run_capture(ferryd.uninstall)
        self.assertEqual(out.strip(), "uninstalled")
        self.assertFalse(ferryd.PLIST.exists())
        self.assertEqual(self.launchctl_calls(), [f"launchctl bootout gui/{os.getuid()}/com.anurag.ferry"])

    def test_uninstall_without_a_plist_is_fine(self):
        self.assertEqual(self.run_capture(ferryd.uninstall).strip(), "uninstalled")

    def test_status_without_agent_or_socket(self):
        out = self.run_capture(ferryd.status)
        self.assertIn("agent: not loaded", out)
        self.assertIn("phone app: unknown (agent not answering)", out)
        self.assertNotIn("--- log ---", out)

    def test_status_reports_state_line_and_phone(self):
        self.set_state("launchctl_print_com.anurag.ferry", "com.anurag.ferry = {\n\tpid = 5\n\tstate = running\n}\n")
        self.set_state("adb_devices", "List of devices attached\nPIXEL\tdevice\n")
        ferryd.serve_control(StubLink(model="Pixel 7 Pro"))
        out = self.run_capture(ferryd.status)
        self.assertIn("agent: state = running", out)
        self.assertIn("phone app: connected Pixel 7 Pro", out)
        self.assertIn("PIXEL\tdevice", out)

    def test_status_shows_only_the_last_ten_log_lines(self):
        ferryd.LOG.write_text("\n".join(f"line {i}" for i in range(30)) + "\n")
        out = self.run_capture(ferryd.status)
        self.assertIn("--- log ---", out)
        self.assertIn("line 29", out)
        self.assertIn("line 20", out)
        self.assertNotIn("line 19", out)

    def test_status_survives_a_binary_log(self):
        ferryd.LOG.write_bytes(b"ok\n\xff\xfe broken\n")
        out = self.run_capture(ferryd.status)
        self.assertIn("broken", out)


class Main(HubTestCase):
    def test_no_arguments_runs_the_hub(self):
        with mock.patch.object(ferryd, "serve") as serve:
            ferryd.main([])
        serve.assert_called_once_with()

    def test_install_uninstall_status_dispatch(self):
        for cmd in ("install", "uninstall", "status"):
            with self.subTest(cmd=cmd), mock.patch.object(ferryd, cmd) as fn:
                ferryd.main([cmd])
            fn.assert_called_once_with()

    def test_extra_arguments_are_ignored(self):
        with mock.patch.object(ferryd, "status") as fn:
            ferryd.main(["status", "--verbose"])
        fn.assert_called_once_with()

    def test_adb_connect_prints_the_serial_and_logs_to_stderr(self):
        out = io.StringIO()
        with mock.patch.object(ferryd, "ensure_connected", return_value="SER1"), contextlib.redirect_stdout(out):
            ferryd.main(["adb-connect"])
            self.assertIs(ferryd.LOG_STREAM, sys.stderr)
        self.assertEqual(out.getvalue(), "SER1\n")

    def test_adb_connect_without_phone_exits_1_and_prints_nothing(self):
        out = io.StringIO()
        with mock.patch.object(ferryd, "ensure_connected", return_value=None), contextlib.redirect_stdout(out):
            with self.assertRaises(SystemExit) as cm:
                ferryd.main(["adb-connect"])
        self.assertEqual(cm.exception.code, 1)
        self.assertEqual(out.getvalue(), "")

    def test_unknown_command_prints_the_module_docstring(self):
        for argv in (["help"], ["--help"], ["bogus"], ["INSTALL"]):
            with self.subTest(argv=argv):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    ferryd.main(argv)
                self.assertTrue(out.getvalue().startswith("ferryd: the Mac side of Ferry"))
                self.assertIn("ferryd adb-connect", out.getvalue())

    def test_empty_string_argument_runs_the_hub(self):
        with mock.patch.object(ferryd, "serve") as serve:
            ferryd.main([""])
        serve.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
