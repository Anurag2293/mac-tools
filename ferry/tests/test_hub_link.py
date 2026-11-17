"""Link: authentication, message dispatch, sending, screenshots, and the listening loop."""
import hashlib
import socket
import threading
import time
import unittest
from unittest import mock

from hubenv import HubTestCase, ferryd


def tcp_pair():
    """Two connected loopback TCP sockets (AF_UNIX pairs reject TCP_NODELAY, which _handle sets)."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    cli = socket.create_connection(srv.getsockname())
    conn, _ = srv.accept()
    srv.close()
    cli.settimeout(5)
    return conn, cli


class TimeoutSpy:
    """Delegates to a socket but lets a test observe and rewrite settimeout calls."""

    def __init__(self, sock, rewrite=None):
        self._s = sock
        self.seen = []
        self._rewrite = rewrite or (lambda t: t)

    def settimeout(self, t):
        self.seen.append(t)
        self._s.settimeout(self._rewrite(t))

    def __getattr__(self, name):
        return getattr(self._s, name)


class LinkCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.state_obj = ferryd.State()
        self.link = ferryd.Link(self.state_obj)
        self.errors = []
        self.threads = []
        self.addCleanup(self._close_all)
        self.sockets = []

    def _close_all(self):
        for s in self.sockets:
            try:
                s.close()
            except OSError:
                pass
        for t in self.threads:
            t.join(3)
        self.assertEqual(self.errors, [], "uncaught exceptions in link threads")

    def connect(self, token="tok", addr=("100.1.1.1", 5555), hello=None):
        """Start _handle on one end of a TCP pair; returns the phone-side socket."""
        conn, cli = tcp_pair()
        self.sockets += [conn, cli]

        def run():
            try:
                self.link._handle(conn, addr, token)
            except BaseException as e:  # noqa: BLE001 - record anything escaping the handler
                self.errors.append(repr(e))

        t = threading.Thread(target=run, daemon=True)
        t.start()
        self.threads.append(t)
        if hello is not False:
            ferryd.write_frame(cli, hello if hello is not None else {"t": "hello", "token": token, "model": "Pixel 7 Pro"})
        return cli

    def wait_for(self, cond, what="condition", timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return
            time.sleep(0.01)
        self.fail(f"timed out waiting for {what}")

    def expect_closed(self, cli):
        cli.settimeout(3)
        try:
            self.assertEqual(cli.recv(1), b"", "peer should have been closed")
        except ConnectionError:
            pass


class Authentication(LinkCase):
    def test_good_token_gets_welcome_and_is_registered(self):
        cli = self.connect()
        self.assertEqual(ferryd.read_frame(cli)[0], {"t": "welcome"})
        self.wait_for(lambda: self.link.connected, "registration")
        self.assertEqual(self.link.model, "Pixel 7 Pro")
        self.assertIn("link: Pixel 7 Pro connected from 100.1.1.1", self.log_text())

    def test_model_defaults_to_phone(self):
        cli = self.connect(hello={"t": "hello", "token": "tok"})
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        self.assertEqual(self.link.model, "phone")

    def test_wrong_token_gets_error_frame_and_is_closed(self):
        cli = self.connect(hello={"t": "hello", "token": "nope"})
        self.assertEqual(ferryd.read_frame(cli)[0], {"t": "error", "err": "bad token"})
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)
        self.assertIn("bad token", self.log_text())

    def test_missing_and_odd_tokens_are_rejected(self):
        for hello in ({"t": "hello"}, {"t": "hello", "token": None}, {"t": "hello", "token": 0},
                      {"t": "hello", "token": ""}, {"t": "hello", "token": ["tok"]}, {"t": "hello", "token": "tok "},
                      {"t": "hello", "token": "TOK"}, {"t": "hello", "token": "tokx"}, {"t": "hello", "token": "to"}):
            with self.subTest(hello=hello):
                cli = self.connect(hello=hello)
                self.assertEqual(ferryd.read_frame(cli)[0]["err"], "bad token")
                self.expect_closed(cli)
        self.assertFalse(self.link.connected)

    def test_non_ascii_token_is_rejected_without_crashing_the_handler(self):
        cli = self.connect(hello={"t": "hello", "token": "tökén"})
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)

    def test_first_frame_must_be_hello(self):
        cli = self.connect(hello={"t": "clip", "text": "hi", "token": "tok"})
        self.assertEqual(ferryd.read_frame(cli)[0]["t"], "error")
        self.expect_closed(cli)
        self.assertEqual(self.state_obj.synced, "")

    def test_garbage_instead_of_a_frame_closes_the_connection(self):
        cli = self.connect(hello=False)
        cli.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)

    def test_non_object_hello_is_rejected_cleanly(self):
        for payload in (b"[1,2]", b'"hello"', b"null", b"7"):
            with self.subTest(payload=payload):
                cli = self.connect(hello=False)
                cli.sendall(len(payload).to_bytes(4, "big") + payload)
                self.expect_closed(cli)
        self.assertFalse(self.link.connected)

    def test_peer_closing_during_handshake_is_quiet(self):
        cli = self.connect(hello=False)
        cli.close()
        for t in self.threads:
            t.join(3)
        self.assertFalse(self.link.connected)

    def test_silent_connection_is_dropped_after_handshake_timeout(self):
        conn, cli = tcp_pair()
        self.sockets += [conn, cli]
        spy = TimeoutSpy(conn, rewrite=lambda t: 0.2 if t == 15 else t)
        t = threading.Thread(target=self.link._handle, args=(spy, ("100.1.1.1", 1), "tok"), daemon=True)
        t.start()
        self.threads.append(t)
        self.expect_closed(cli)
        self.assertEqual(spy.seen[0], 15)

    def test_post_auth_idle_timeout_is_75_seconds(self):
        conn, cli = tcp_pair()
        self.sockets += [conn, cli]
        spy = TimeoutSpy(conn)
        t = threading.Thread(target=self.link._handle, args=(spy, ("100.1.1.1", 1), "tok"), daemon=True)
        t.start()
        self.threads.append(t)
        ferryd.write_frame(cli, {"t": "hello", "token": "tok"})
        ferryd.read_frame(cli)
        self.assertEqual(spy.seen, [15, 75])

    def test_token_comparison_is_constant_time(self):
        with mock.patch.object(ferryd.hmac, "compare_digest", wraps=ferryd.hmac.compare_digest) as cd:
            cli = self.connect()
            ferryd.read_frame(cli)
        cd.assert_called()


class PhoneIpCheck(LinkCase):
    def test_other_ip_is_dropped_before_reading_anything(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.9.9.9\n")
        cli = self.connect(addr=("100.1.1.1", 5))
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)
        self.assertIn("rejected connection from 100.1.1.1 (expected 100.9.9.9)", self.log_text())

    def test_other_ip_with_the_right_token_is_still_rejected(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.9.9.9")
        cli = self.connect(addr=("100.1.1.1", 5))
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)

    def test_matching_ip_is_accepted_despite_whitespace_in_the_file(self):
        ferryd.TAILNET_HOST_FILE.write_text("  100.1.1.1 \n")
        cli = self.connect(addr=("100.1.1.1", 5))
        self.assertEqual(ferryd.read_frame(cli)[0]["t"], "welcome")

    def test_without_a_phone_host_file_any_ip_with_the_token_is_accepted(self):
        # Pinned: with no phone_host file the IP check is skipped and only the token protects the hub.
        cli = self.connect(addr=("100.77.7.7", 5))
        self.assertEqual(ferryd.read_frame(cli)[0]["t"], "welcome")

    def test_empty_phone_host_file_skips_the_ip_check_too(self):
        ferryd.TAILNET_HOST_FILE.write_text("\n")
        cli = self.connect(addr=("100.77.7.7", 5))
        self.assertEqual(ferryd.read_frame(cli)[0]["t"], "welcome")

    def test_ip_comparison_is_exact_not_prefix(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.1.1.1")
        cli = self.connect(addr=("100.1.1.10", 5))
        self.expect_closed(cli)
        cli = self.connect(addr=("100.1.1.1", 5))
        self.assertEqual(ferryd.read_frame(cli)[0]["t"], "welcome")

    def test_unreadable_phone_host_file_does_not_leave_a_dangling_connection(self):
        ferryd.TAILNET_HOST_FILE.write_bytes(b"\xff\xfe\x00")
        cli = self.connect()
        self.expect_closed(cli)
        self.assertFalse(self.link.connected)


class Sessions(LinkCase):
    def test_second_phone_replaces_the_first_and_closes_it(self):
        first = self.connect(hello={"t": "hello", "token": "tok", "model": "A"})
        ferryd.read_frame(first)
        self.wait_for(lambda: self.link.model == "A")
        second = self.connect(hello={"t": "hello", "token": "tok", "model": "B"})
        ferryd.read_frame(second)
        self.wait_for(lambda: self.link.model == "B")
        self.expect_closed(first)
        self.assertTrue(self.link.connected)
        self.assertTrue(self.link.send({"t": "ping"}))
        self.assertEqual(ferryd.read_frame(second)[0], {"t": "ping"})

    def test_old_connection_ending_does_not_disconnect_the_new_one(self):
        first = self.connect()
        ferryd.read_frame(first)
        self.wait_for(lambda: self.link.connected)
        second = self.connect(hello={"t": "hello", "token": "tok", "model": "B"})
        ferryd.read_frame(second)
        self.wait_for(lambda: self.link.model == "B")
        time.sleep(0.2)
        self.assertTrue(self.link.connected)
        self.assertNotIn("disconnected", self.log_text())

    def test_disconnect_clears_the_connection_and_logs(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        cli.close()
        self.wait_for(lambda: not self.link.connected, "disconnect")
        self.wait_for(lambda: "link: disconnected" in self.log_text(), "log line")

    def test_frames_after_welcome_reach_dispatch(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        with mock.patch.object(ferryd, "mac_set") as ms, mock.patch.object(ferryd, "show_text"):
            ferryd.write_frame(cli, {"t": "clip", "text": "from phone"})
            self.wait_for(lambda: ms.called, "mac_set")
        ms.assert_called_once_with("from phone")

    def test_malformed_frame_after_auth_drops_the_session_and_frees_the_slot(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        junk = b"this is not json at all, not even close!!!"
        cli.sendall(len(junk).to_bytes(4, "big") + junk)
        self.wait_for(lambda: not self.link.connected, "disconnect")
        self.expect_closed(cli)

    def test_a_message_that_breaks_dispatch_must_not_leave_a_dead_connection_registered(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        ferryd.write_frame(cli, {"t": "clip", "text": 12345})
        self.wait_for(lambda: not self.link.connected, "link released after a bad message")
        self.expect_closed(cli)

    def test_non_dict_frame_after_auth_releases_the_slot(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        cli.sendall((2).to_bytes(4, "big") + b"[]")
        self.wait_for(lambda: not self.link.connected, "link released")

    def test_file_name_that_cannot_be_saved_drops_the_session_cleanly(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        with mock.patch.object(ferryd, "show_received"):
            ferryd.write_frame(cli, {"t": "file", "name": "a\x00b"}, b"data")
            self.wait_for(lambda: not self.link.connected, "link released")


class Dispatch(LinkCase):
    def setUp(self):
        super().setUp()
        self.shown = []
        for name, side in (("show_text", lambda t, s=False: self.shown.append(("text", t, s))),
                           ("show_received", lambda p: self.shown.append(("file", p)))):
            p = mock.patch.object(ferryd, name, side)
            p.start()
            self.addCleanup(p.stop)

    def clipboard(self):
        p = self.state / "clipboard"
        return p.read_text() if p.exists() else None

    def test_pong_is_ignored_silently(self):
        self.link._dispatch({"t": "pong"}, None)
        self.assertEqual(self.log_text(), "")

    def test_unknown_type_is_logged(self):
        self.link._dispatch({"t": "weird"}, None)
        self.assertIn("link: unknown message weird", self.log_text())

    def test_missing_type_is_logged_as_none(self):
        self.link._dispatch({}, None)
        self.assertIn("unknown message None", self.log_text())

    def test_clip_sets_mac_clipboard_and_shows_a_card(self):
        self.link._dispatch({"t": "clip", "text": "hello"}, None)
        self.assertEqual(self.clipboard(), "hello")
        self.assertEqual(self.state_obj.synced, "hello")
        self.assertEqual(self.shown, [("text", "hello", False)])

    def test_clip_sensitive_flag_is_forwarded(self):
        self.link._dispatch({"t": "clip", "text": "pw", "sensitive": True}, None)
        self.assertEqual(self.shown, [("text", "pw", True)])
        self.assertIn("sensitive", self.log_text())
        self.assertNotIn("pw'", self.log_text())

    def test_clip_echo_and_empty_are_dropped(self):
        self.link._dispatch({"t": "clip", "text": "same"}, None)
        self.link._dispatch({"t": "clip", "text": "same"}, None)
        self.link._dispatch({"t": "clip", "text": ""}, None)
        self.link._dispatch({"t": "clip"}, None)
        self.assertEqual(len(self.shown), 1)

    def test_clip_text_is_logged_by_length_only(self):
        self.link._dispatch({"t": "clip", "text": "super secret value"}, None)
        self.assertNotIn("super secret", self.log_text())
        self.assertIn("18 chars", self.log_text())

    def test_clip_img_is_written_and_synced_text_refreshed(self):
        with mock.patch.object(ferryd, "mac_set_image") as msi:
            self.link._dispatch({"t": "clip_img", "mime": "image/jpeg"}, b"JPEGDATA")
        msi.assert_called_once_with(b"JPEGDATA", "image/jpeg")
        self.assertIn("image, 8 bytes", self.log_text())

    def test_clip_img_defaults_to_png(self):
        with mock.patch.object(ferryd, "mac_set_image") as msi:
            self.link._dispatch({"t": "clip_img"}, b"x")
        msi.assert_called_once_with(b"x", "image/png")

    def test_clip_img_that_we_sent_ourselves_is_not_echoed_back(self):
        self.state_obj.sent_image = hashlib.sha256(b"PNG").digest()
        with mock.patch.object(ferryd, "mac_set_image") as msi:
            self.link._dispatch({"t": "clip_img"}, b"PNG")
        msi.assert_not_called()

    def test_clip_img_records_pasteboard_change_count_to_ignore_it(self):
        with mock.patch.object(ferryd, "mac_set_image"), mock.patch.object(ferryd, "change_count", lambda: 77):
            self.link._dispatch({"t": "clip_img"}, b"x")
        self.assertEqual(self.state_obj.own_change, 77)

    def test_clip_img_without_data_is_reported_unknown(self):
        # Pinned: a clip_img frame with no body falls through to the unknown-message log line.
        self.link._dispatch({"t": "clip_img"}, None)
        self.assertIn("unknown message clip_img", self.log_text())

    def test_file_is_saved_to_downloads_and_previewed(self):
        self.link._dispatch({"t": "file", "name": "a.txt"}, b"content")
        path = self.downloads / "a.txt"
        self.assertEqual(path.read_bytes(), b"content")
        self.assertEqual(self.shown, [("file", path)])
        self.assertIn(f"phone -> Mac file {path}", self.log_text())

    def test_second_file_with_same_name_gets_a_number(self):
        self.link._dispatch({"t": "file", "name": "a.txt"}, b"one")
        self.link._dispatch({"t": "file", "name": "a.txt"}, b"two")
        self.assertEqual((self.downloads / "a.txt").read_bytes(), b"one")
        self.assertEqual((self.downloads / "a (1).txt").read_bytes(), b"two")

    def test_hostile_file_name_cannot_escape_downloads(self):
        self.link._dispatch({"t": "file", "name": "../../.ssh/authorized_keys"}, b"ssh-rsa AAA")
        self.assertEqual([p.name for p in self.downloads.iterdir()], ["authorized_keys"])
        self.assertFalse((self.root / ".ssh").exists())

    def test_file_without_name_is_called_from_phone(self):
        self.link._dispatch({"t": "file"}, b"x")
        self.assertTrue((self.downloads / "from-phone").exists())

    def test_empty_file_is_reported_unknown(self):
        # Pinned: a zero-byte file is not saved; the frame has no body, so it hits the unknown branch.
        self.link._dispatch({"t": "file", "name": "empty.txt"}, None)
        self.assertFalse((self.downloads / "empty.txt").exists())
        self.assertIn("unknown message file", self.log_text())

    def test_shot_reply_completes_the_pending_request(self):
        entry = [threading.Event(), None, None]
        self.link.pending["abc"] = entry
        self.link._dispatch({"t": "shot", "id": "abc", "ok": True}, b"PNG")
        self.assertTrue(entry[0].is_set())
        self.assertEqual((entry[1], entry[2]), (b"PNG", None))

    def test_shot_failure_carries_the_error(self):
        entry = [threading.Event(), None, None]
        self.link.pending["abc"] = entry
        self.link._dispatch({"t": "shot", "id": "abc", "ok": False, "err": "secure screen"}, None)
        self.assertEqual((entry[1], entry[2]), (None, "secure screen"))
        self.assertTrue(entry[0].is_set())

    def test_shot_failure_without_message_says_failed(self):
        entry = [threading.Event(), None, None]
        self.link.pending["abc"] = entry
        self.link._dispatch({"t": "shot", "id": "abc"}, None)
        self.assertEqual(entry[2], "failed")

    def test_shot_for_unknown_or_expired_id_is_ignored(self):
        self.link._dispatch({"t": "shot", "id": "nobody", "ok": True}, b"PNG")
        self.link._dispatch({"t": "shot", "ok": True}, b"PNG")
        self.assertEqual(self.link.pending, {})

    def test_shot_ok_without_data_is_reported_as_no_error_and_no_png(self):
        # Pinned: ok=true with no body yields (None, None); serve_control then answers "err None".
        entry = [threading.Event(), None, None]
        self.link.pending["abc"] = entry
        self.link._dispatch({"t": "shot", "id": "abc", "ok": True}, None)
        self.assertEqual((entry[1], entry[2]), (None, None))


class Sending(LinkCase):
    def test_send_without_a_phone_returns_false(self):
        self.assertFalse(self.link.send({"t": "clip", "text": "x"}))

    def test_send_writes_a_frame(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        self.assertTrue(self.link.send({"t": "clip_img", "mime": "image/png"}, b"PNGDATA"))
        hdr, data = ferryd.read_frame(cli)
        self.assertEqual((hdr["t"], hdr["size"], data), ("clip_img", 7, b"PNGDATA"))

    def test_failed_send_drops_the_connection_and_closes_it(self):
        bad = mock.MagicMock()
        bad.sendall.side_effect = BrokenPipeError("gone")
        self.link.conn = bad
        self.assertFalse(self.link.send({"t": "ping"}))
        self.assertFalse(self.link.connected)
        bad.close.assert_called_once()
        self.assertIn("send failed", self.log_text())

    def test_failed_send_survives_close_errors(self):
        bad = mock.MagicMock()
        bad.sendall.side_effect = OSError("x")
        bad.close.side_effect = OSError("y")
        self.link.conn = bad
        self.assertFalse(self.link.send({"t": "ping"}))

    def test_concurrent_senders_do_not_interleave_frames(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        payloads = [bytes([i]) * 200_000 for i in range(1, 6)]
        threads = [threading.Thread(target=self.link.send, args=({"t": "clip_img", "n": i}, p))
                   for i, p in enumerate(payloads, 1)]
        for t in threads:
            t.start()
        got = {}
        for _ in payloads:
            hdr, data = ferryd.read_frame(cli)
            got[hdr["n"]] = data
        for t in threads:
            t.join()
        self.assertEqual(got, {i: p for i, p in enumerate(payloads, 1)})

    def test_connected_property(self):
        self.assertFalse(self.link.connected)
        self.link.conn = object()
        self.assertTrue(self.link.connected)


class Screenshot(LinkCase):
    def test_not_connected(self):
        self.assertEqual(self.link.screenshot(), (None, "phone app not connected"))
        self.assertEqual(self.link.pending, {})

    def test_roundtrip_through_a_real_connection(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)

        def phone():
            hdr, _ = ferryd.read_frame(cli)
            assert hdr["t"] == "shot"
            ferryd.write_frame(cli, {"t": "shot", "id": hdr["id"], "ok": True}, b"\x89PNGdata")

        t = threading.Thread(target=phone)
        t.start()
        png, err = self.link.screenshot(timeout=5)
        t.join()
        self.assertEqual((png, err), (b"\x89PNGdata", None))
        self.assertEqual(self.link.pending, {})

    def test_phone_reports_failure(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)

        def phone():
            hdr, _ = ferryd.read_frame(cli)
            ferryd.write_frame(cli, {"t": "shot", "id": hdr["id"], "ok": False, "err": "no service"})

        t = threading.Thread(target=phone)
        t.start()
        self.assertEqual(self.link.screenshot(timeout=5), (None, "no service"))
        t.join()

    def test_timeout_cleans_up_the_pending_entry(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        t0 = time.time()
        self.assertEqual(self.link.screenshot(timeout=0.2), (None, "timed out waiting for the phone"))
        self.assertLess(time.time() - t0, 2)
        self.assertEqual(self.link.pending, {})

    def test_late_reply_after_timeout_is_ignored(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        self.link.screenshot(timeout=0.1)
        hdr, _ = ferryd.read_frame(cli)
        ferryd.write_frame(cli, {"t": "shot", "id": hdr["id"], "ok": True}, b"LATE")
        time.sleep(0.1)
        self.assertTrue(self.link.connected)
        self.assertEqual(self.link.pending, {})

    def test_request_ids_are_unique_and_twelve_hex_chars(self):
        ids = []
        orig = self.link.send
        self.link.send = lambda hdr, data=None: (ids.append(hdr["id"]), False)[1]
        for _ in range(20):
            self.link.screenshot()
        self.link.send = orig
        self.assertEqual(len(set(ids)), 20)
        self.assertTrue(all(len(i) == 12 and int(i, 16) >= 0 for i in ids))

    def test_two_requests_in_flight_get_their_own_answers(self):
        cli = self.connect()
        ferryd.read_frame(cli)
        self.wait_for(lambda: self.link.connected)
        results = {}

        def ask(n):
            results[n] = self.link.screenshot(timeout=5)

        threads = [threading.Thread(target=ask, args=(n,)) for n in (1, 2)]
        for t in threads:
            t.start()
        reqs = [ferryd.read_frame(cli)[0] for _ in (1, 2)]
        for hdr in reversed(reqs):
            ferryd.write_frame(cli, {"t": "shot", "id": hdr["id"], "ok": True}, hdr["id"].encode())
        for t in threads:
            t.join()
        self.assertEqual({r[0] for r in results.values()}, {r["id"].encode() for r in reqs})


class Listening(LinkCase):
    """Link._serve on loopback with an ephemeral port (never the real hub port)."""

    def start_server(self):
        self.stop = threading.Event()
        servers = []
        real_create = socket.create_server

        def create_server(addr, *a, **k):
            assert addr[0] == "127.0.0.1", addr
            s = real_create(("127.0.0.1", 0), *a, **k)
            servers.append(s)
            return s

        def fake_ip():
            if self.stop.is_set():
                raise SystemExit
            return "127.0.0.1"

        for target, value in ((ferryd, ("tailscale_ip", fake_ip)), (ferryd.socket, ("create_server", create_server)),
                              (ferryd, ("LINK_PORT", 0))):
            p = mock.patch.object(target, value[0], value[1])
            p.start()
            self.addCleanup(p.stop)

        def shutdown():
            self.stop.set()
            for s in servers:
                s.close()

        self.addCleanup(shutdown)
        t = threading.Thread(target=self.link._serve, daemon=True)
        t.start()
        self.wait_for(lambda: servers, "listener")
        return servers[0].getsockname()[1]

    def test_accepts_a_phone_end_to_end(self):
        port = self.start_server()
        token = ferryd.link_token()
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sockets.append(c)
        ferryd.write_frame(c, {"t": "hello", "token": token, "model": "Pixel"})
        self.assertEqual(ferryd.read_frame(c)[0], {"t": "welcome"})
        self.wait_for(lambda: self.link.connected)
        self.assertIn("listening on 127.0.0.1", self.log_text())

    def test_rejects_a_bad_token_over_tcp(self):
        port = self.start_server()
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sockets.append(c)
        ferryd.write_frame(c, {"t": "hello", "token": "wrong"})
        self.assertEqual(ferryd.read_frame(c)[0]["err"], "bad token")
        self.assertFalse(self.link.connected)

    def test_rejects_other_source_ips_over_tcp(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.9.9.9\n")
        port = self.start_server()
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sockets.append(c)
        try:
            ferryd.write_frame(c, {"t": "hello", "token": ferryd.link_token()})
        except OSError:
            pass
        self.expect_closed(c)
        self.assertFalse(self.link.connected)

    def test_serves_several_connections_concurrently(self):
        port = self.start_server()
        token = ferryd.link_token()
        silent = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sockets.append(silent)
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sockets.append(c)
        ferryd.write_frame(c, {"t": "hello", "token": token})
        self.assertEqual(ferryd.read_frame(c)[0]["t"], "welcome")

    def test_waits_while_there_is_no_tailnet_address(self):
        calls = []
        stop = threading.Event()

        def fake_ip():
            calls.append(1)
            if len(calls) >= 2:
                raise SystemExit
            return None

        sleeps = []
        with mock.patch.object(ferryd, "tailscale_ip", fake_ip), \
                mock.patch.object(ferryd.time, "sleep", lambda s: sleeps.append(s)):
            t = threading.Thread(target=self.link._serve, daemon=True)
            t.start()
            t.join(3)
        self.assertEqual(sleeps, [15])
        self.assertFalse(t.is_alive())

    def test_retries_when_the_port_is_taken(self):
        calls = []

        def create_server(addr, *a, **k):
            raise OSError("Address already in use")

        def fake_ip():
            calls.append(1)
            if len(calls) >= 2:
                raise SystemExit
            return "127.0.0.1"

        sleeps = []
        with mock.patch.object(ferryd, "tailscale_ip", fake_ip), mock.patch.object(ferryd, "LINK_PORT", 0), \
                mock.patch.object(ferryd.socket, "create_server", create_server), \
                mock.patch.object(ferryd.time, "sleep", lambda s: sleeps.append(s)):
            t = threading.Thread(target=self.link._serve, daemon=True)
            t.start()
            t.join(3)
        self.assertEqual(sleeps, [15])
        self.assertIn("cannot listen on 127.0.0.1:0", self.log_text())


if __name__ == "__main__":
    unittest.main()
