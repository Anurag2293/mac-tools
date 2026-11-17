"""Control-socket peer for the CLI tests: python3 fake_ctl_hub.py MODE [PNG].

Modes: real-ok, real-err, real-connected, real-disconnected run the real ferryd.serve_control
with a stub link; garbage, truncated, ok-no-size, empty-reply answer with hand-written replies.
Binds only HOME/.config/ferry/ctl.sock (HOME is the test sandbox).
"""
import importlib.machinery
import importlib.util
import os
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
home = Path(os.environ["HOME"])
if not str(home).startswith("/private/tmp/ferry-test."):
    sys.exit("fake_ctl_hub: HOME is not a test sandbox")

mode = sys.argv[1]
png = Path(sys.argv[2]).read_bytes() if len(sys.argv) > 2 else b""
sock_path = home / ".config/ferry/ctl.sock"

loader = importlib.machinery.SourceFileLoader("ferryd_ctl", str(HERE.parent / "hub/ferryd"))
spec = importlib.util.spec_from_loader("ferryd_ctl", loader)
ferryd = importlib.util.module_from_spec(spec)
loader.exec_module(ferryd)
assert ferryd.CTL_SOCK == sock_path, ferryd.CTL_SOCK


class StubLink:
    model = "Pixel 7 Pro"

    def __init__(self, mode):
        self.mode = mode

    @property
    def connected(self):
        return self.mode != "real-disconnected"

    def screenshot(self, timeout=15):
        if self.mode == "real-ok":
            return png, None
        return None, "phone app not connected"


def raw_server(reply):
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    sock_path.unlink(missing_ok=True)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    srv.listen(4)
    while True:
        c, _ = srv.accept()
        c.recv(64)
        c.sendall(reply)
        c.close()


if mode.startswith("real-"):
    ferryd.serve_control(StubLink(mode))
    while True:
        time.sleep(1)
else:
    replies = {
        "garbage": b"bogus\n",
        "truncated": b"ok 100\n" + b"x" * 10,
        "ok-no-size": b"ok\n",
        "empty-reply": b"",
    }
    raw_server(replies[mode])
