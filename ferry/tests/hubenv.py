"""Loads hub/ferryd as a module inside a sandbox and guards against touching the real hub or phone.

Import this module before anything else in a hub test:

    from hubenv import ferryd, HubTestCase

What it guarantees:
  * HOME points into a throwaway directory before ferryd is imported, so its module-level paths
    (~/.config/ferry, ~/Downloads, ~/Library/...) never name the real ones.
  * Each test case gets fresh paths patched over those constants, and ferryd.ENV gets a PATH that
    holds only the fake adb/pbcopy/launchctl/... from tests/fakebin.
  * subprocess.run/Popen refuse any executable outside that fake directory (and the Python
    interpreter); socket connect/bind refuse the real control socket and the real hub port.
"""
import atexit
import importlib.machinery
import importlib.util
import os
import pwd
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TESTS_DIR = Path(__file__).resolve().parent
HUB_PATH = TESTS_DIR.parent / "hub" / "ferryd"
REAL_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
REAL_HUB_PORT = 47821
REAL_CTL_SOCK = str(REAL_HOME / ".config/ferry/ctl.sock")

ROOT = Path(tempfile.mkdtemp(prefix="ferry-hub-test.", dir="/tmp")).resolve()
atexit.register(shutil.rmtree, ROOT, ignore_errors=True)
os.environ["HOME"] = str(ROOT / "home")
os.environ["PATH"] = f"{ROOT / 'bin'}:/usr/bin:/bin"
(ROOT / "home").mkdir()

FAKE_BIN = ROOT / "bin"
FAKE_BIN.mkdir()
for _f in ("adb", "osascript", "launchctl", "sleep"):
    shutil.copy(TESTS_DIR / "fakebin" / _f, FAKE_BIN / _f)
for _f in ("pbcopy", "pbpaste", "sips", "scrcpy", "tailscale"):
    shutil.copy(TESTS_DIR / "fakebin_hub" / _f, FAKE_BIN / _f)
for _p in FAKE_BIN.iterdir():
    _p.chmod(0o755)


def _check_address(addr):
    if isinstance(addr, str) and (REAL_CTL_SOCK in addr or ".config/ferry/ctl.sock" in addr and str(ROOT) not in addr):
        raise AssertionError(f"SAFETY: refusing to touch the real control socket {addr}")
    if isinstance(addr, tuple) and len(addr) >= 2 and addr[1] == REAL_HUB_PORT:
        raise AssertionError(f"SAFETY: refusing to use the real hub port {addr}")


def _guard_socket(name):
    orig = getattr(socket.socket, name)

    def guarded(self, address, *a, **k):
        _check_address(address)
        return orig(self, address, *a, **k)

    setattr(socket.socket, name, guarded)


for _name in ("connect", "connect_ex", "bind"):
    _guard_socket(_name)

_real_run = subprocess.run
_real_popen = subprocess.Popen


def _check_exe(args, env):
    exe = args if isinstance(args, (str, bytes, os.PathLike)) else args[0]
    exe = os.fsdecode(exe)
    search = (env or os.environ).get("PATH", "")
    path = exe if os.sep in exe else shutil.which(exe, path=search)
    real = str(Path(path).resolve()) if path else ""
    if not real or not (Path(real).parent == FAKE_BIN or real == str(Path(sys.executable).resolve())
                        or real.startswith(str(ROOT) + os.sep)):
        raise AssertionError(f"SAFETY: refusing to run {exe!r} (resolved {path!r}) outside the sandbox")


def _safe_run(args, *a, **k):
    _check_exe(args, k.get("env"))
    return _real_run(args, *a, **k)


class _SafePopen(_real_popen):
    def __init__(self, args, *a, **k):
        _check_exe(args, k.get("env"))
        super().__init__(args, *a, **k)


subprocess.run = _safe_run
subprocess.Popen = _SafePopen

_loader = importlib.machinery.SourceFileLoader("ferryd", str(HUB_PATH))
_spec = importlib.util.spec_from_loader("ferryd", _loader)
ferryd = importlib.util.module_from_spec(_spec)
sys.modules["ferryd"] = ferryd
_loader.exec_module(ferryd)

assert str(ferryd.LINK_DIR).startswith(str(ROOT)), ferryd.LINK_DIR
assert str(ferryd.DOWNLOADS).startswith(str(ROOT)), ferryd.DOWNLOADS
assert str(ferryd.PLIST).startswith(str(ROOT)), ferryd.PLIST


class HubTestCase(unittest.TestCase):
    """Fresh sandbox paths, fake binaries and quiet logging for every test."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="t.", dir=ROOT))
        self.state = self.root / "state"
        self.state.mkdir()
        self.calls = self.root / "calls.log"
        self.calls.touch()
        self.link_dir = self.root / "config"
        self.link_dir.mkdir()
        self.downloads = self.root / "Downloads"
        self.log_lines = []
        env = {
            "PATH": f"{FAKE_BIN}:/usr/bin:/bin",
            "HOME": str(self.root),
            "FERRY_TEST_LOG": str(self.calls),
            "FERRY_TEST_STATE": str(self.state),
            "LANG": "en_US.UTF-8",
        }
        patches = {
            "LINK_DIR": self.link_dir,
            "TOKEN_FILE": self.link_dir / "token",
            "CTL_SOCK": self.link_dir / "ctl.sock",
            "LAST_ADDR_FILE": self.link_dir / "adb_addr",
            "TAILNET_HOST_FILE": self.link_dir / "phone_host",
            "DOWNLOADS": self.downloads,
            "PLIST": self.root / "LaunchAgents" / "com.anurag.ferry.plist",
            "LOG": self.root / "ferry.log",
            "PHONEPEEK_BIN": self.root / "ferry-peek",
            "TAILSCALE": str(FAKE_BIN / "tailscale"),
            "ENV": env,
            "LOG_STREAM": mock.MagicMock(),
            "last_scan": 0.0,
            "change_count": None,
            "_text_card": None,
        }
        p = mock.patch.dict(os.environ, {"FERRY_TEST_LOG": env["FERRY_TEST_LOG"], "FERRY_TEST_STATE": env["FERRY_TEST_STATE"]})
        p.start()
        self.addCleanup(p.stop)
        for name, value in patches.items():
            p = mock.patch.object(ferryd, name, value)
            p.start()
            self.addCleanup(p.stop)
        for name in ("PLIST", "LOG", "PHONEPEEK_BIN", "TOKEN_FILE", "CTL_SOCK"):
            self.assertTrue(str(getattr(ferryd, name)).startswith(str(ROOT)), name)
        self.assertTrue(ferryd.ENV["PATH"].startswith(f"{FAKE_BIN}:"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.addCleanup(self._reap_children)
        self._children = []

    def _reap_children(self):
        for p in getattr(self, "_children", []):
            try:
                p.kill()
                p.wait(2)
            except Exception:
                pass

    # --- helpers --------------------------------------------------------------------------------

    def set_state(self, name, content):
        (self.state / name).write_text(content if isinstance(content, str) else content.decode())

    def call_log(self):
        return self.calls.read_text()

    def log_text(self):
        """Everything ferryd.log() printed (LOG_STREAM is a mock)."""
        return "".join(str(c.args[0]) for c in ferryd.LOG_STREAM.write.call_args_list)

    def track(self, proc):
        self._children.append(proc)
        return proc
