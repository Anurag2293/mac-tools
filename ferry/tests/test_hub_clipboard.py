"""Mac clipboard helpers, corner previews, notifications, State and the Mac-to-phone watcher."""
import hashlib
import os
import stat
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from hubenv import HubTestCase, ferryd


class MacText(HubTestCase):
    def test_get_reads_the_clipboard(self):
        self.set_state("clipboard", "hello\nworld")
        self.assertEqual(ferryd.mac_get(), "hello\nworld")

    def test_get_empty_clipboard(self):
        self.assertEqual(ferryd.mac_get(), "")

    def test_get_replaces_invalid_utf8(self):
        (self.state / "clipboard").write_bytes(b"ok \xff\xfe end")
        self.assertEqual(ferryd.mac_get(), "ok �� end")

    def test_get_times_out_to_empty_text(self):
        with mock.patch.object(ferryd.subprocess, "run", side_effect=subprocess.TimeoutExpired("pbpaste", 5)):
            self.assertEqual(ferryd.mac_get(), "")

    def test_set_writes_exact_utf8_bytes(self):
        ferryd.mac_set("日本語 ✓ \U0001f600\nline2")
        self.assertEqual((self.state / "clipboard").read_bytes(), "日本語 ✓ \U0001f600\nline2".encode())

    def test_set_empty_string(self):
        self.set_state("clipboard", "old")
        ferryd.mac_set("")
        self.assertEqual((self.state / "clipboard").read_bytes(), b"")

    def test_set_large_text(self):
        text = "x" * 1_000_000
        ferryd.mac_set(text)
        self.assertEqual(len((self.state / "clipboard").read_bytes()), 1_000_000)

    def test_roundtrip(self):
        ferryd.mac_set("round trip  ")
        self.assertEqual(ferryd.mac_get(), "round trip  ")


class MacImages(HubTestCase):
    def setUp(self):
        super().setUp()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        p = mock.patch.object(tempfile, "tempdir", str(self.tmp))
        p.start()
        self.addCleanup(p.stop)

    def leftovers(self):
        return sorted(os.listdir(self.tmp))

    def test_get_image_returns_png_bytes(self):
        (self.state / "clip_image").write_bytes(b"\x89PNGDATA")
        self.assertEqual(ferryd.mac_get_image(), b"\x89PNGDATA")
        self.assertEqual(self.leftovers(), [])

    def test_get_image_script_targets_the_temp_file(self):
        (self.state / "clip_image").write_bytes(b"x")
        ferryd.mac_get_image()
        log = self.call_log()
        self.assertIn("«class PNGf»", log)
        self.assertIn(f'POSIX file "{self.tmp}/', log)

    def test_no_image_on_the_clipboard(self):
        self.assertIsNone(ferryd.mac_get_image())
        self.assertEqual(self.leftovers(), [])

    def test_empty_image_is_ignored(self):
        (self.state / "clip_image").write_bytes(b"")
        self.assertIsNone(ferryd.mac_get_image())

    def test_oversize_image_is_ignored_and_limit_is_inclusive(self):
        (self.state / "clip_image").write_bytes(b"12345")
        with mock.patch.object(ferryd, "MAX_IMAGE", 4):
            self.assertIsNone(ferryd.mac_get_image())
        with mock.patch.object(ferryd, "MAX_IMAGE", 5):
            self.assertEqual(ferryd.mac_get_image(), b"12345")
        self.assertEqual(self.leftovers(), [])

    def test_osascript_timeout_returns_none_and_cleans_up(self):
        with mock.patch.object(ferryd.subprocess, "run", side_effect=subprocess.TimeoutExpired("osascript", 10)):
            self.assertIsNone(ferryd.mac_get_image())
        self.assertEqual(self.leftovers(), [])

    def test_set_image_png(self):
        ferryd.mac_set_image(b"PNGBYTES", "image/png")
        self.assertEqual((self.state / "set_image_data").read_bytes(), b"PNGBYTES")
        self.assertIn("as «class PNGf»)", self.call_log())
        self.assertNotIn("sips", self.call_log())
        self.assertEqual(self.leftovers(), [])

    def test_set_image_jpeg_uses_the_jpeg_class_and_extension(self):
        ferryd.mac_set_image(b"JPEGBYTES", "image/jpeg")
        self.assertEqual((self.state / "set_image_data").read_bytes(), b"JPEGBYTES")
        self.assertIn("as JPEG picture)", self.call_log())
        self.assertIn(".jpg", self.call_log())
        self.assertNotIn("sips", self.call_log())

    def test_other_formats_are_converted_to_png_first(self):
        for mime in ("image/webp", "image/heic", "image/gif", "application/octet-stream", "image/jpg", ""):
            with self.subTest(mime=mime):
                self.calls.write_text("")
                (self.state / "set_image_data").unlink(missing_ok=True)
                ferryd.mac_set_image(b"RAW", mime)
                self.assertIn("sips -s format png", self.call_log())
                self.assertEqual((self.state / "set_image_data").read_bytes(), b"CONVERTED")
                self.assertIn("as «class PNGf»)", self.call_log())
                self.assertEqual(self.leftovers(), [])

    def test_temp_file_is_removed_even_when_osascript_fails(self):
        real = subprocess.run

        def run(args, *a, **k):
            if args[0] == "osascript":
                raise subprocess.TimeoutExpired("osascript", 10)
            return real(args, *a, **k)

        with mock.patch.object(ferryd.subprocess, "run", run):
            with self.assertRaises(subprocess.TimeoutExpired):
                ferryd.mac_set_image(b"x", "image/png")
        self.assertEqual(self.leftovers(), [])

    def test_temp_file_is_private(self):
        modes = []
        real = subprocess.run

        def run(args, *a, **k):
            if args[0] == "osascript":
                path = args[2].split('POSIX file "')[1].split('"')[0]
                modes.append(stat.S_IMODE(os.stat(path).st_mode))
            return real(args, *a, **k)

        with mock.patch.object(ferryd.subprocess, "run", run):
            ferryd.mac_set_image(b"x", "image/png")
        self.assertEqual(modes, [0o600])


class Notifications(HubTestCase):
    def wait_for_call(self, text, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.call_log():
                return
            time.sleep(0.02)
        self.fail(f"{text!r} not in {self.call_log()!r}")

    def test_notify_builds_a_display_notification_script(self):
        ferryd.notify("From phone", "Saved a.txt to Downloads")
        self.wait_for_call('display notification "Saved a.txt to Downloads" with title "From phone"')

    def test_notify_escapes_quotes_and_backslashes(self):
        ferryd.notify("T", 'say "hi" \\ done')
        self.wait_for_call('display notification "say \\"hi\\" \\\\ done" with title "T"')

    def test_file_names_cannot_break_out_of_the_notification_string(self):
        ferryd.notify("From phone", 'x" & (do shell script "touch /tmp/pwned") & "')
        self.wait_for_call("display notification")
        script = self.call_log()
        self.assertIn('x\\" & (do shell script \\"touch /tmp/pwned\\") & \\"', script)
        self.assertFalse(os.path.exists("/tmp/pwned"))


class Previews(HubTestCase):
    def make_peek(self, body):
        ferryd.PHONEPEEK_BIN.write_text("#!/bin/bash\n" + body)
        ferryd.PHONEPEEK_BIN.chmod(0o755)

    def wait_for(self, cond, what, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            if cond():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {what}")

    def test_show_received_without_peek_falls_back_to_a_notification(self):
        path = self.downloads / "a.txt"
        with mock.patch.object(ferryd, "notify") as n:
            ferryd.show_received(path)
        n.assert_called_once_with("From phone", "Saved a.txt to Downloads")

    def test_show_received_launches_peek_detached_with_reveal(self):
        self.make_peek('echo "peek $*" >> "$FERRY_TEST_LOG"\n')
        path = self.downloads / "my file.png"
        with mock.patch.object(ferryd, "notify") as n:
            ferryd.show_received(path)
        self.wait_for(lambda: "peek --show" in self.call_log(), "peek call")
        self.assertIn(f"peek --show {path} --reveal", self.call_log())
        n.assert_not_called()

    def test_show_received_starts_a_new_session_so_peek_outlives_the_hub(self):
        popen = mock.MagicMock()
        self.make_peek("")
        with mock.patch.object(ferryd.subprocess, "Popen", popen):
            ferryd.show_received(self.downloads / "a.png")
        self.assertIs(popen.call_args.kwargs["start_new_session"], True)

    def test_show_text_without_peek_does_nothing(self):
        with mock.patch.object(ferryd.subprocess, "Popen") as popen:
            ferryd.show_text("hello")
        popen.assert_not_called()

    def test_show_text_passes_text_on_stdin_not_in_arguments(self):
        out = self.root / "stdin.txt"
        self.make_peek(f'echo "peek $*" >> "$FERRY_TEST_LOG"\ncat > {out}\n')
        ferryd.show_text("secret 日本")
        self.wait_for(lambda: out.exists() and out.read_text() == "secret 日本", "stdin contents")
        self.assertNotIn("secret", self.call_log())
        self.assertIn("peek --text", self.call_log())
        self.assertNotIn("--sensitive", self.call_log())

    def test_show_text_sensitive_flag(self):
        self.make_peek('echo "peek $*" >> "$FERRY_TEST_LOG"\ncat >/dev/null\n')
        ferryd.show_text("pw", sensitive=True)
        self.wait_for(lambda: "peek --text --sensitive" in self.call_log(), "sensitive call")

    def test_a_new_card_replaces_the_one_still_showing(self):
        self.make_peek('cat >/dev/null\nsleep 30\n')
        ferryd.show_text("one")
        first = ferryd._text_card
        self.track(first)
        ferryd.show_text("two")
        self.track(ferryd._text_card)
        self.wait_for(lambda: first.poll() is not None, "first card terminated")
        self.assertIsNone(ferryd._text_card.poll())

    def test_a_finished_card_is_not_terminated_again(self):
        self.make_peek("cat >/dev/null\n")
        ferryd.show_text("one")
        first = ferryd._text_card
        first.wait(3)
        with mock.patch.object(first, "terminate") as term:
            ferryd.show_text("two")
        term.assert_not_called()
        self.track(ferryd._text_card)

    def test_unlaunchable_peek_is_logged_not_raised(self):
        ferryd.PHONEPEEK_BIN.write_text("#!/bin/bash\n")
        ferryd.PHONEPEEK_BIN.chmod(0o644)
        ferryd.show_text("hello")
        self.assertIn("text card failed", self.log_text())

    def test_peek_that_exits_before_reading_stdin_is_tolerated(self):
        self.make_peek("exit 0\n")
        time.sleep(0.05)
        ferryd.show_text("x" * 200_000)
        self.track(ferryd._text_card)


class StateCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.shown = []
        p = mock.patch.object(ferryd, "show_text", lambda t, s=False: self.shown.append((t, s)))
        p.start()
        self.addCleanup(p.stop)

    def test_initial_synced_text_is_the_current_clipboard(self):
        self.set_state("clipboard", "already here")
        self.assertEqual(ferryd.State().synced, "already here")

    def test_from_phone_applies_new_text_once(self):
        st = ferryd.State()
        self.assertTrue(st.from_phone("fresh"))
        self.assertFalse(st.from_phone("fresh"))
        self.assertEqual(ferryd.mac_get(), "fresh")
        self.assertEqual(self.shown, [("fresh", False)])

    def test_text_equal_to_the_mac_clipboard_at_startup_is_not_re_applied(self):
        self.set_state("clipboard", "same")
        self.assertFalse(ferryd.State().from_phone("same"))
        self.assertEqual(self.call_log(), "")

    def test_empty_and_none_are_ignored(self):
        st = ferryd.State()
        self.assertFalse(st.from_phone(""))
        self.assertFalse(st.from_phone(None))
        self.assertEqual(self.shown, [])

    def test_sensitive_flag_is_passed_through_and_logged_without_text(self):
        st = ferryd.State()
        st.from_phone("hunter2", sensitive=True)
        self.assertEqual(self.shown, [("hunter2", True)])
        self.assertIn("7 chars, sensitive", self.log_text())
        self.assertNotIn("hunter2", self.log_text())

    def test_changing_back_to_an_older_value_is_applied(self):
        st = ferryd.State()
        st.from_phone("a")
        st.from_phone("b")
        self.assertTrue(st.from_phone("a"))

    def test_concurrent_identical_texts_apply_once(self):
        import threading
        st = ferryd.State()
        results = []
        threads = [threading.Thread(target=lambda: results.append(st.from_phone("dup"))) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(results.count(True), 1)

    def test_fields_start_empty(self):
        st = ferryd.State()
        self.assertIsNone(st.session)
        self.assertIsNone(st.own_change)
        self.assertIsNone(st.sent_image)


class FakeLink:
    def __init__(self, connected=True, accept=True):
        self.connected = connected
        self.accept = accept
        self.sent = []

    def send(self, hdr, data=None):
        self.sent.append((hdr, data))
        return self.accept


class PushText(HubTestCase):
    def test_uses_the_app_link_when_connected(self):
        link = FakeLink()
        st = ferryd.State()
        self.assertTrue(ferryd.push_text(st, link, "hi"))
        self.assertEqual(link.sent, [({"t": "clip", "text": "hi"}, None)])

    def test_reports_failure_when_the_app_link_refuses(self):
        link = FakeLink(accept=False)
        self.assertFalse(ferryd.push_text(ferryd.State(), link, "hi"))

    def test_app_link_wins_over_an_adb_session(self):
        st = ferryd.State()
        st.session = mock.MagicMock()
        link = FakeLink()
        ferryd.push_text(st, link, "hi")
        st.session.send_clipboard.assert_not_called()

    def test_falls_back_to_a_live_adb_session(self):
        st = ferryd.State()
        st.session = mock.MagicMock()
        st.session.dead.is_set.return_value = False
        self.assertTrue(ferryd.push_text(st, FakeLink(connected=False), "hi"))
        st.session.send_clipboard.assert_called_once_with("hi")

    def test_dead_session_and_no_session_fail(self):
        st = ferryd.State()
        self.assertFalse(ferryd.push_text(st, FakeLink(connected=False), "hi"))
        st.session = mock.MagicMock()
        st.session.dead.is_set.return_value = True
        self.assertFalse(ferryd.push_text(st, FakeLink(connected=False), "hi"))
        st.session.send_clipboard.assert_not_called()


class StopLoop(Exception):
    pass


class WatchMac(HubTestCase):
    """watch_mac with a scripted clipboard and a sleep that ends the loop after N iterations."""

    def run_watch(self, link, texts, ccs=None, images=(), state=None, iterations=None):
        state = state or ferryd.State()
        texts = list(texts)
        ccs_iter = iter(ccs or [])
        images = iter(images)
        n = iterations or len(texts)
        sleeps = []

        def sleep(s):
            sleeps.append(s)
            if len(sleeps) > n:
                raise StopLoop

        patches = [
            mock.patch.object(ferryd.time, "sleep", sleep),
            mock.patch.object(ferryd, "mac_get", lambda: texts.pop(0) if texts else ""),
            mock.patch.object(ferryd, "mac_get_image", lambda: next(images, None)),
        ]
        if ccs is not None:
            first = ccs[0]
            patches.append(mock.patch.object(ferryd, "change_count", lambda: next(ccs_iter, ccs[-1])))
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        with self.assertRaises(StopLoop):
            ferryd.watch_mac(state, link)
        self.assertTrue(all(s == ferryd.POLL_SECONDS for s in sleeps))
        return state

    def test_new_text_is_pushed_and_marked_synced(self):
        link = FakeLink()
        st = self.run_watch(link, ["copied on mac"])
        self.assertEqual(link.sent, [({"t": "clip", "text": "copied on mac"}, None)])
        self.assertEqual(st.synced, "copied on mac")
        self.assertIn("Mac -> phone (13 chars)", self.log_text())

    def test_unchanged_text_is_pushed_only_once(self):
        link = FakeLink()
        self.run_watch(link, ["a", "a", "a"])
        self.assertEqual(len(link.sent), 1)

    def test_text_that_came_from_the_phone_is_not_echoed(self):
        link = FakeLink()
        st = ferryd.State()
        st.synced = "from phone"
        self.run_watch(link, ["from phone"], state=st)
        self.assertEqual(link.sent, [])

    def test_failed_push_is_retried_on_the_next_poll(self):
        link = FakeLink(accept=False)
        st = self.run_watch(link, ["a", "a"])
        self.assertEqual(len(link.sent), 2)
        self.assertNotEqual(st.synced, "a")

    def test_empty_clipboard_is_never_pushed(self):
        link = FakeLink()
        self.run_watch(link, ["", ""])
        self.assertEqual(link.sent, [])

    def test_adb_transport_is_labelled_in_the_log(self):
        st = ferryd.State()
        st.session = mock.MagicMock()
        st.session.dead.is_set.return_value = False
        self.run_watch(FakeLink(connected=False), ["via adb"], state=st)
        self.assertIn("Mac -> phone (7 chars, adb)", self.log_text())
        st.session.send_clipboard.assert_called_once_with("via adb")

    def test_changed_pasteboard_without_text_sends_the_image(self):
        link = FakeLink()
        st = self.run_watch(link, ["", ""], ccs=[1, 2, 2], images=[b"PNGBYTES"])
        self.assertEqual(link.sent, [({"t": "clip_img", "mime": "image/png"}, b"PNGBYTES")])
        self.assertEqual(st.sent_image, hashlib.sha256(b"PNGBYTES").digest())

    def test_image_is_sent_once_per_pasteboard_change(self):
        link = FakeLink()
        self.run_watch(link, ["", "", "", ""], ccs=[1, 2, 2, 2, 2], images=[b"A", b"B"])
        self.assertEqual([d for _, d in link.sent], [b"A"])

    def test_each_new_change_sends_a_new_image(self):
        link = FakeLink()
        self.run_watch(link, ["", "", ""], ccs=[1, 2, 3, 3], images=[b"A", b"B"])
        self.assertEqual([d for _, d in link.sent], [b"A", b"B"])

    def test_pasteboard_changes_we_made_ourselves_are_skipped(self):
        link = FakeLink()
        st = ferryd.State()
        st.own_change = 2
        self.run_watch(link, ["", ""], ccs=[1, 2, 2], images=[b"A"], state=st)
        self.assertEqual(link.sent, [])

    def test_text_on_the_pasteboard_wins_over_image_handling(self):
        link = FakeLink()
        self.run_watch(link, ["some text", "some text"], ccs=[1, 2, 2], images=[b"A"])
        self.assertEqual([h["t"] for h, _ in link.sent], ["clip"])

    def test_no_image_is_read_while_the_app_is_not_connected(self):
        link = FakeLink(connected=False)
        with mock.patch.object(ferryd, "mac_get_image") as mgi:
            self.run_watch(link, ["", ""], ccs=[1, 2, 2])
        mgi.assert_not_called()

    def test_clipboard_without_an_image_sends_nothing(self):
        link = FakeLink()
        self.run_watch(link, ["", ""], ccs=[1, 2, 2], images=[None])
        self.assertEqual(link.sent, [])

    def test_rejected_image_is_not_recorded_as_sent(self):
        link = FakeLink(accept=False)
        st = self.run_watch(link, ["", ""], ccs=[1, 2, 2], images=[b"A"])
        self.assertIsNone(st.sent_image)

    def test_without_change_counts_images_are_disabled(self):
        link = FakeLink()
        with mock.patch.object(ferryd, "mac_get_image") as mgi:
            self.run_watch(link, ["", ""])
        mgi.assert_not_called()


if __name__ == "__main__":
    unittest.main()
