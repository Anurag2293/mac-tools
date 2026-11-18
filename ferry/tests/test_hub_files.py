"""Token file, download naming, tailnet address parsing and other state-on-disk helpers."""
import os
import stat
import unittest
from unittest import mock

from hubenv import HubTestCase, ferryd


class LinkToken(HubTestCase):
    def test_first_call_creates_a_long_random_token_with_private_mode(self):
        tok = ferryd.link_token()
        self.assertRegex(tok, r"^[0-9a-f]{64}$")
        self.assertEqual(stat.S_IMODE(ferryd.TOKEN_FILE.stat().st_mode), 0o600)
        self.assertEqual(ferryd.TOKEN_FILE.read_text(), tok + "\n")

    def test_token_is_never_group_or_world_readable_at_any_moment(self):
        old = os.umask(0o022)
        try:
            with mock.patch.object(ferryd.Path, "chmod", lambda *a, **k: None):
                ferryd.link_token()
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(ferryd.TOKEN_FILE.stat().st_mode) & 0o077, 0,
                         "the token file must be created private, not chmod-ed after the fact")

    def test_existing_token_is_reused_and_stripped(self):
        ferryd.TOKEN_FILE.write_text("  secret-token \n")
        self.assertEqual(ferryd.link_token(), "secret-token")
        self.assertEqual(ferryd.TOKEN_FILE.read_text(), "  secret-token \n")

    def test_creates_the_config_directory(self):
        ferryd.LINK_DIR.rmdir()
        ferryd.link_token()
        self.assertTrue(ferryd.TOKEN_FILE.exists())

    def test_two_tokens_differ(self):
        a = ferryd.link_token()
        ferryd.TOKEN_FILE.unlink()
        self.assertNotEqual(a, ferryd.link_token())

    def test_empty_token_file_is_replaced_not_accepted(self):
        ferryd.TOKEN_FILE.write_text("")
        tok = ferryd.link_token()
        self.assertRegex(tok, r"^[0-9a-f]{64}$")
        self.assertEqual(ferryd.TOKEN_FILE.read_text().strip(), tok)

    def test_whitespace_only_token_file_is_replaced(self):
        ferryd.TOKEN_FILE.write_text(" \n\n")
        self.assertRegex(ferryd.link_token(), r"^[0-9a-f]{64}$")


class UniqueDownload(HubTestCase):
    def name(self, raw):
        return ferryd.unique_download(raw).name

    def test_plain_name_goes_to_downloads_and_creates_it(self):
        p = ferryd.unique_download("photo.jpg")
        self.assertEqual(p, self.downloads / "photo.jpg")
        self.assertTrue(self.downloads.is_dir())

    def test_collisions_get_numbered_before_the_extension(self):
        self.downloads.mkdir()
        (self.downloads / "a.txt").touch()
        self.assertEqual(self.name("a.txt"), "a (1).txt")
        (self.downloads / "a (1).txt").touch()
        self.assertEqual(self.name("a.txt"), "a (2).txt")

    def test_collision_without_extension(self):
        self.downloads.mkdir()
        (self.downloads / "README").touch()
        self.assertEqual(self.name("README"), "README (1)")

    def test_double_extension_numbers_before_the_last_one(self):
        self.downloads.mkdir()
        (self.downloads / "x.tar.gz").touch()
        self.assertEqual(self.name("x.tar.gz"), "x.tar (1).gz")

    def test_directories_in_the_name_are_dropped(self):
        for raw in ("../../etc/passwd", "/etc/passwd", "a/b/c.txt", "..\\..\\evil.exe", "C:\\Users\\x\\a.txt", "a/../b.txt"):
            with self.subTest(raw=raw):
                p = ferryd.unique_download(raw)
                self.assertEqual(p.parent, self.downloads)
        self.assertEqual(self.name("../../etc/passwd"), "passwd")
        self.assertEqual(self.name("..\\..\\evil.exe"), "evil.exe")
        self.assertEqual(self.name("a/b/c.txt"), "c.txt")

    def test_leading_dots_are_stripped_so_nothing_hidden_or_relative_is_written(self):
        self.assertEqual(self.name(".bashrc"), "bashrc")
        self.assertEqual(self.name("...hidden.txt"), "hidden.txt")

    def test_names_with_no_usable_part_fall_back(self):
        for raw in ("", ".", "..", "...", "/", "a/", "dir\\", "/..", " "):
            with self.subTest(raw=raw):
                n = self.name(raw)
                self.assertTrue(n == "from-phone" or n == " ", n)
        self.assertEqual(self.name(""), "from-phone")
        self.assertEqual(self.name(".."), "from-phone")
        self.assertEqual(self.name("a/"), "from-phone")

    def test_unicode_and_spaces_survive(self):
        self.assertEqual(self.name("スクリーンショット 1.png"), "スクリーンショット 1.png")
        self.assertEqual(self.name("my file (copy).txt"), "my file (copy).txt")

    def test_shell_and_applescript_metacharacters_stay_inside_the_name(self):
        for raw in ('a"b.txt', "a'b.txt", "$(touch x).txt", "a;b|c.txt", "a`b`.txt", "a\nb.txt"):
            with self.subTest(raw=raw):
                p = ferryd.unique_download(raw)
                self.assertEqual(p.parent, self.downloads)
                self.assertEqual(p.name, raw)

    def test_result_never_overwrites_an_existing_file(self):
        self.downloads.mkdir()
        seen = set()
        for _ in range(5):
            p = ferryd.unique_download("same.bin")
            self.assertNotIn(p, seen)
            seen.add(p)
            p.write_bytes(b"x")
        self.assertEqual(len(list(self.downloads.iterdir())), 5)

    def test_overlong_name_raises_an_os_error_the_link_handler_catches(self):
        with self.assertRaises(OSError):
            ferryd.unique_download("a" * 300 + ".txt").write_bytes(b"x")

    def test_nul_byte_in_name_raises_a_value_error_the_link_handler_catches(self):
        with self.assertRaises(ValueError):
            ferryd.unique_download("a\x00b.txt").write_bytes(b"x")


class TailscaleIp(HubTestCase):
    def ifconfig(self, text):
        return mock.patch.object(ferryd, "run", return_value=(0, text))

    def test_picks_the_cgnat_address(self):
        out = "lo0: x\n\tinet 127.0.0.1 netmask 0xff000000\nen0: y\n\tinet 192.168.1.4 netmask 0xffffff00\nutun4: z\n\tinet 100.101.102.103 --> 100.101.102.103 netmask 0xffffffff\n"
        with self.ifconfig(out):
            self.assertEqual(ferryd.tailscale_ip(), "100.101.102.103")

    def test_range_edges(self):
        for ip, ok in (("100.64.0.0", True), ("100.127.255.255", True), ("100.63.255.255", False),
                       ("100.128.0.0", False), ("10.64.0.1", False), ("101.64.0.1", False)):
            with self.subTest(ip=ip), self.ifconfig(f"\tinet {ip} netmask 0xff\n"):
                self.assertEqual(ferryd.tailscale_ip(), ip if ok else None)

    def test_first_match_wins(self):
        with self.ifconfig("\tinet 100.70.0.1 netmask 0xff\n\tinet 100.90.0.1 netmask 0xff\n"):
            self.assertEqual(ferryd.tailscale_ip(), "100.70.0.1")

    def test_ignores_ipv6_and_garbage_lines(self):
        out = "\tinet6 fe80::1%lo0 prefixlen 64\n\tinet\n\tinet notanip netmask 0x0\n\tinet 999.1.1.1 netmask 0x0\nrandom\n\n"
        with self.ifconfig(out):
            self.assertIsNone(ferryd.tailscale_ip())

    def test_empty_output(self):
        with self.ifconfig(""):
            self.assertIsNone(ferryd.tailscale_ip())

    def test_non_inet_line_that_mentions_an_address_is_ignored(self):
        with self.ifconfig("\tbroadcast 100.100.0.1\n\tnetmask 100.100.0.2\n"):
            self.assertIsNone(ferryd.tailscale_ip())


class EnvAndTools(HubTestCase):
    def test_module_env_prefers_homebrew_and_forces_utf8(self):
        # ENV is built at import time from os.environ; check the construction rule via the source of truth.
        import importlib.util, importlib.machinery
        with mock.patch.dict(os.environ, {"PATH": "/usr/bin:/bin"}):
            loader = importlib.machinery.SourceFileLoader("ferryd_env_probe", str(ferryd.__file__ if hasattr(ferryd, "__file__") else ""))
            spec = importlib.util.spec_from_loader("ferryd_env_probe", loader)
            m = importlib.util.module_from_spec(spec)
            loader.exec_module(m)
        self.assertEqual(m.ENV["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        self.assertEqual(m.ENV["LANG"], "en_US.UTF-8")
        self.assertEqual(m.ENV["LC_ALL"], "en_US.UTF-8")

    def test_find_server_prefers_the_env_override(self):
        jar = self.root / "server.jar"
        jar.write_text("x")
        with mock.patch.dict(os.environ, {"SCRCPY_SERVER_PATH": str(jar)}):
            self.assertEqual(ferryd.find_server(), str(jar))

    def test_find_server_skips_a_missing_override_and_exits_when_nothing_found(self):
        with mock.patch.dict(os.environ, {"SCRCPY_SERVER_PATH": str(self.root / "nope")}), \
                mock.patch.object(ferryd.os.path, "isfile", return_value=False):
            with self.assertRaises(SystemExit) as cm:
                ferryd.find_server()
        self.assertIn("scrcpy-server not found", str(cm.exception))

    def test_find_server_falls_through_to_the_homebrew_path(self):
        with mock.patch.dict(os.environ, {"SCRCPY_SERVER_PATH": ""}), \
                mock.patch.object(ferryd.os.path, "isfile", side_effect=lambda p: p == "/opt/homebrew/share/scrcpy/scrcpy-server"):
            self.assertEqual(ferryd.find_server(), "/opt/homebrew/share/scrcpy/scrcpy-server")

    def test_scrcpy_version_parses_second_word(self):
        self.assertEqual(ferryd.scrcpy_version(), "3.3.1")
        self.set_state("scrcpy_version", "scrcpy 5.0.1 <https://x>\n")
        self.assertEqual(ferryd.scrcpy_version(), "5.0.1")

    def test_scrcpy_version_unreadable_exits(self):
        self.set_state("scrcpy_version", "")
        with self.assertRaises(SystemExit) as cm:
            ferryd.scrcpy_version()
        self.assertIn("could not read scrcpy version", str(cm.exception))

    def test_run_returns_code_and_decoded_output(self):
        self.set_state("adb_devices", "List of devices attached\n\xe3\x81\x82\n")
        code, out = ferryd.run("adb", "devices")
        self.assertEqual(code, 0)
        self.assertIn("List of devices attached", out)

    def test_run_maps_timeouts_to_124(self):
        import subprocess
        with mock.patch.object(ferryd.subprocess, "run", side_effect=subprocess.TimeoutExpired("adb", 1)):
            self.assertEqual(ferryd.run("adb", "devices", timeout=1), (124, ""))

    def test_adb_helper_prefixes_serial(self):
        ferryd.adb("shell", "ls", serial="S1")
        ferryd.adb("devices")
        log = self.call_log()
        self.assertIn("adb -s S1 shell ls", log)
        self.assertIn("adb devices", log)


class Discovery(HubTestCase):
    def devices(self, *lines):
        self.set_state("adb_devices", "List of devices attached\n" + "\n".join(lines) + "\n")

    def test_connected_serial_skips_header_and_non_device_states(self):
        self.devices("AAA\toffline", "BBB\tunauthorized", "CCC\tdevice", "DDD\tdevice")
        self.assertEqual(ferryd.connected_serial(), "CCC")

    def test_connected_serial_none_when_empty_or_garbage(self):
        self.devices()
        self.assertIsNone(ferryd.connected_serial())
        self.devices("", "garbage", "* daemon started successfully *")
        self.assertIsNone(ferryd.connected_serial())

    def test_connected_serial_accepts_wireless_serials(self):
        self.devices("100.1.2.3:41234\tdevice")
        self.assertEqual(ferryd.connected_serial(), "100.1.2.3:41234")

    def test_try_connect_returns_serial_after_successful_connect(self):
        self.set_state("adb_out_connect", "connected to 10.0.0.2:5555\n")
        self.devices("10.0.0.2:5555\tdevice")
        with mock.patch.object(ferryd.time, "sleep"):
            self.assertEqual(ferryd.try_connect("10.0.0.2:5555"), "10.0.0.2:5555")

    def test_try_connect_failure_returns_none_without_listing_devices(self):
        self.set_state("adb_out_connect", "failed to connect to '10.0.0.2:5555'\n")
        self.devices("OTHER\tdevice")
        self.assertIsNone(ferryd.try_connect("10.0.0.2:5555"))
        self.assertNotIn("adb devices", self.call_log())

    def test_remember_writes_the_address_and_creates_the_directory(self):
        ferryd.LAST_ADDR_FILE.parent.rmdir()
        ferryd.remember("1.2.3.4:5555")
        self.assertEqual(ferryd.LAST_ADDR_FILE.read_text(), "1.2.3.4:5555\n")

    def test_ensure_connected_prefers_an_attached_device(self):
        self.devices("USB1\tdevice")
        self.assertEqual(ferryd.ensure_connected(), "USB1")
        self.assertNotIn("mdns", self.call_log())

    def test_ensure_connected_uses_mdns_and_remembers_the_address(self):
        self.set_state("adb_mdns", "List of discovered mdns services\nx\t_adb-tls-pairing._tcp\t1.1.1.1:1\ny\t_adb-tls-connect._tcp\t10.0.0.5:44444\n")
        self.set_state("adb_out_connect", "connected to 10.0.0.5:44444\n")
        answers = iter(["List of devices attached\n", "List of devices attached\n10.0.0.5:44444\tdevice\n"])
        real = ferryd.adb

        def adb(*a, **k):
            if a[:1] == ("devices",):
                return 0, next(answers)
            return real(*a, **k)

        with mock.patch.object(ferryd, "adb", adb), mock.patch.object(ferryd.time, "sleep"):
            self.assertEqual(ferryd.ensure_connected(), "10.0.0.5:44444")
        self.assertEqual(ferryd.LAST_ADDR_FILE.read_text().strip(), "10.0.0.5:44444")
        self.assertIn("connect 10.0.0.5:44444", self.call_log())
        self.assertNotIn("connect 1.1.1.1:1", self.call_log())

    def test_ensure_connected_falls_back_to_the_last_address(self):
        ferryd.LAST_ADDR_FILE.write_text("9.9.9.9:5555\n")
        self.set_state("adb_out_connect", "connected to 9.9.9.9:5555\n")
        answers = iter(["List of devices attached\n", "List of devices attached\n9.9.9.9:5555\tdevice\n"])
        real = ferryd.adb

        def adb(*a, **k):
            if a[:1] == ("devices",):
                return 0, next(answers)
            return real(*a, **k)

        with mock.patch.object(ferryd, "adb", adb), mock.patch.object(ferryd.time, "sleep"):
            self.assertEqual(ferryd.ensure_connected(), "9.9.9.9:5555")
        self.assertIn("adb connect 9.9.9.9:5555", self.call_log())

    def test_ensure_connected_returns_none_when_everything_fails(self):
        with mock.patch.object(ferryd, "scan_tailnet", return_value=None) as scan:
            self.assertIsNone(ferryd.ensure_connected())
        scan.assert_called_once()


class TailnetOnline(HubTestCase):
    def status(self, obj=None, rc=0, raw=None):
        import json
        self.set_state("tailscale_json", raw if raw is not None else json.dumps(obj))
        self.set_state("tailscale_rc", str(rc))

    def test_online_peer(self):
        self.status({"Peer": {"k": {"TailscaleIPs": ["100.1.1.1"], "Online": True}}})
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))

    def test_offline_peer_is_the_only_false(self):
        self.status({"Peer": {"k": {"TailscaleIPs": ["100.1.1.1", "fd7a::1"], "Online": False}}})
        self.assertFalse(ferryd.tailnet_online("100.1.1.1"))
        self.assertFalse(ferryd.tailnet_online("fd7a::1"))

    def test_unknown_peer_is_assumed_online(self):
        self.status({"Peer": {"k": {"TailscaleIPs": ["100.9.9.9"], "Online": False}}})
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))

    def test_cli_failure_or_bad_json_is_assumed_online(self):
        self.status(raw="", rc=1)
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))
        self.status(raw="not json", rc=0)
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))

    def test_missing_peer_section_or_ip_list(self):
        self.status({"Peer": None})
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))
        self.status({"Peer": {"k": {"Online": False}}})
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))
        self.status({})
        self.assertTrue(ferryd.tailnet_online("100.1.1.1"))


class ScanTailnet(HubTestCase):
    def test_does_nothing_without_a_phone_host_file(self):
        with mock.patch.object(ferryd, "scan_open_ports") as scan:
            self.assertIsNone(ferryd.scan_tailnet())
        scan.assert_not_called()

    def test_rate_limited_to_one_scan_per_interval(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.1.1.1\n")
        with mock.patch.object(ferryd, "scan_open_ports", return_value=[]) as scan, \
                mock.patch.object(ferryd, "tailnet_online", return_value=True):
            ferryd.scan_tailnet()
            ferryd.scan_tailnet()
        self.assertEqual(scan.call_count, 1)

    def test_offline_peer_skips_the_scan(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.1.1.1\n")
        with mock.patch.object(ferryd, "scan_open_ports") as scan, \
                mock.patch.object(ferryd, "tailnet_online", return_value=False):
            self.assertIsNone(ferryd.scan_tailnet())
        scan.assert_not_called()

    def test_blank_host_file_is_ignored(self):
        ferryd.TAILNET_HOST_FILE.write_text("  \n")
        with mock.patch.object(ferryd, "scan_open_ports") as scan:
            self.assertIsNone(ferryd.scan_tailnet())
        scan.assert_not_called()

    def test_first_port_that_accepts_adb_connect_wins_and_is_remembered(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.1.1.1\n")
        tried = []

        def try_connect(addr):
            tried.append(addr)
            return "SER" if addr.endswith(":40002") else None

        with mock.patch.object(ferryd, "scan_open_ports", return_value=[40001, 40002, 40003]), \
                mock.patch.object(ferryd, "tailnet_online", return_value=True), \
                mock.patch.object(ferryd, "try_connect", try_connect):
            self.assertEqual(ferryd.scan_tailnet(), "SER")
        self.assertEqual(tried, ["100.1.1.1:40001", "100.1.1.1:40002"])
        self.assertEqual(ferryd.LAST_ADDR_FILE.read_text().strip(), "100.1.1.1:40002")

    def test_no_port_works(self):
        ferryd.TAILNET_HOST_FILE.write_text("100.1.1.1\n")
        with mock.patch.object(ferryd, "scan_open_ports", return_value=[1, 2]), \
                mock.patch.object(ferryd, "tailnet_online", return_value=True), \
                mock.patch.object(ferryd, "try_connect", return_value=None):
            self.assertIsNone(ferryd.scan_tailnet())
        self.assertFalse(ferryd.LAST_ADDR_FILE.exists())

    def test_scan_open_ports_finds_listening_ports_on_loopback_only(self):
        import socket
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        self.addCleanup(srv.close)
        port = srv.getsockname()[1]
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        closed_port = closed.getsockname()[1]
        closed.close()
        with mock.patch.object(ferryd, "SCAN_PORTS", [closed_port, port]):
            found = ferryd.scan_open_ports("127.0.0.1")
        self.assertEqual(found, [port])


if __name__ == "__main__":
    unittest.main()
