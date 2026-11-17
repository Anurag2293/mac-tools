"""Wire format: u32 header length, JSON header, raw bytes. recv_exact, read_frame, write_frame."""
import json
import socket
import struct
import threading
import unittest

from hubenv import HubTestCase, ferryd


def raw_frame(header, data=b""):
    h = json.dumps(header).encode() if not isinstance(header, bytes) else header
    return struct.pack(">I", len(h)) + h + data


class ProtocolCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.a, self.b = socket.socketpair()
        self.addCleanup(self.a.close)
        self.addCleanup(self.b.close)
        self.a.settimeout(5)
        self.b.settimeout(5)

    def feed(self, payload):
        self.a.sendall(payload)

    def read(self):
        return ferryd.read_frame(self.b)


class RecvExact(ProtocolCase):
    def test_reads_exactly_n_bytes_leaving_the_rest(self):
        self.feed(b"abcdef")
        self.assertEqual(ferryd.recv_exact(self.b, 4), b"abcd")
        self.assertEqual(ferryd.recv_exact(self.b, 2), b"ef")

    def test_zero_bytes_returns_immediately(self):
        self.assertEqual(ferryd.recv_exact(self.b, 0), b"")

    def test_reassembles_data_that_arrives_in_pieces(self):
        def dribble():
            for ch in b"hello":
                self.a.sendall(bytes([ch]))
        t = threading.Thread(target=dribble)
        t.start()
        self.assertEqual(ferryd.recv_exact(self.b, 5), b"hello")
        t.join()

    def test_closed_socket_raises_connection_error(self):
        self.feed(b"ab")
        self.a.close()
        with self.assertRaisesRegex(ConnectionError, "socket closed"):
            ferryd.recv_exact(self.b, 3)

    def test_large_payload(self):
        data = bytes(range(256)) * 4096
        t = threading.Thread(target=self.a.sendall, args=(data,))
        t.start()
        self.assertEqual(ferryd.recv_exact(self.b, len(data)), data)
        t.join()


class WriteFrame(ProtocolCase):
    def test_header_only(self):
        ferryd.write_frame(self.a, {"t": "ping"})
        raw = ferryd.recv_exact(self.b, 4)
        n = struct.unpack(">I", raw)[0]
        self.assertEqual(json.loads(ferryd.recv_exact(self.b, n)), {"t": "ping"})

    def test_data_adds_size_without_mutating_the_callers_dict(self):
        hdr = {"t": "file", "name": "a.txt"}
        ferryd.write_frame(self.a, hdr, b"12345")
        self.assertEqual(hdr, {"t": "file", "name": "a.txt"})
        got, data = self.read()
        self.assertEqual(got, {"t": "file", "name": "a.txt", "size": 5})
        self.assertEqual(data, b"12345")

    def test_empty_data_still_announces_size_zero(self):
        ferryd.write_frame(self.a, {"t": "file"}, b"")
        got, data = self.read()
        self.assertEqual(got["size"], 0)
        self.assertIsNone(data)

    def test_non_ascii_header_roundtrips(self):
        ferryd.write_frame(self.a, {"t": "clip", "text": "日本語 ✓   \U0001f600"})
        got, _ = self.read()
        self.assertEqual(got["text"], "日本語 ✓   \U0001f600")

    def test_wire_layout_is_big_endian_length_prefix(self):
        ferryd.write_frame(self.a, {"t": "x"}, b"ZZ")
        raw = ferryd.recv_exact(self.b, 4 + len(json.dumps({"t": "x", "size": 2})) + 2)
        n = struct.unpack(">I", raw[:4])[0]
        self.assertEqual(raw[4:4 + n], json.dumps({"t": "x", "size": 2}).encode())
        self.assertEqual(raw[4 + n:], b"ZZ")

    def test_header_size_key_is_overridden_when_data_given(self):
        ferryd.write_frame(self.a, {"t": "x", "size": 999}, b"ab")
        got, data = self.read()
        self.assertEqual((got["size"], data), (2, b"ab"))


class ReadFrame(ProtocolCase):
    def test_header_and_body(self):
        self.feed(raw_frame({"t": "file", "size": 3}, b"abc"))
        hdr, data = self.read()
        self.assertEqual(hdr, {"t": "file", "size": 3})
        self.assertEqual(data, b"abc")

    def test_no_size_means_no_data(self):
        self.feed(raw_frame({"t": "pong"}))
        self.assertEqual(self.read(), ({"t": "pong"}, None))

    def test_back_to_back_frames_stay_aligned(self):
        self.feed(raw_frame({"t": "a", "size": 2}, b"xy") + raw_frame({"t": "b"}) + raw_frame({"t": "c", "size": 1}, b"z"))
        self.assertEqual(self.read()[1], b"xy")
        self.assertEqual(self.read()[0]["t"], "b")
        self.assertEqual(self.read()[1], b"z")

    def test_zero_header_length_is_rejected(self):
        self.feed(struct.pack(">I", 0))
        with self.assertRaisesRegex(ConnectionError, "bad header length 0"):
            self.read()

    def test_oversize_header_length_is_rejected_without_reading_it(self):
        self.feed(struct.pack(">I", (4 << 20) + 1))
        with self.assertRaisesRegex(ConnectionError, "bad header length"):
            self.read()

    def test_huge_header_length_from_garbage_text(self):
        self.feed(b"GET / HTTP/1.1\r\n")
        with self.assertRaisesRegex(ConnectionError, "bad header length"):
            self.read()

    def test_header_of_exactly_the_maximum_length_is_accepted(self):
        pad = "x" * ((4 << 20) - len('{"t": "big", "pad": ""}'))
        payload = json.dumps({"t": "big", "pad": pad}).encode()
        self.assertEqual(len(payload), 4 << 20)
        t = threading.Thread(target=self.a.sendall, args=(struct.pack(">I", len(payload)) + payload,))
        t.start()
        hdr, _ = self.read()
        t.join()
        self.assertEqual(hdr["t"], "big")

    def test_negative_size_is_rejected(self):
        self.feed(raw_frame({"t": "file", "size": -1}))
        with self.assertRaisesRegex(ConnectionError, "bad data size -1"):
            self.read()

    def test_size_over_the_limit_is_rejected_without_reading_data(self):
        self.feed(raw_frame({"t": "file", "size": ferryd.MAX_FRAME_DATA + 1}))
        with self.assertRaisesRegex(ConnectionError, "bad data size"):
            self.read()

    def test_size_at_the_limit_is_accepted_up_to_header_check(self):
        self.feed(raw_frame({"t": "file", "size": ferryd.MAX_FRAME_DATA}))
        self.a.shutdown(socket.SHUT_WR)
        with self.assertRaisesRegex(ConnectionError, "socket closed"):
            self.read()

    def test_truncated_body_raises(self):
        self.feed(raw_frame({"t": "file", "size": 10}, b"abc"))
        self.a.close()
        with self.assertRaisesRegex(ConnectionError, "socket closed"):
            self.read()

    def test_truncated_header_raises(self):
        self.feed(struct.pack(">I", 50) + b'{"t":')
        self.a.close()
        with self.assertRaises(ConnectionError):
            self.read()

    def test_peer_closing_before_anything_raises(self):
        self.a.close()
        with self.assertRaises(ConnectionError):
            self.read()

    def test_invalid_json_raises_value_error(self):
        self.feed(raw_frame(b"{not json"))
        with self.assertRaises(ValueError):
            self.read()

    def test_invalid_utf8_header_raises_value_error(self):
        self.feed(raw_frame(b'{"t": "\xff\xfe"}'))
        with self.assertRaises(ValueError):
            self.read()

    def test_size_given_as_a_numeric_string_is_accepted(self):
        self.feed(raw_frame({"t": "file", "size": "3"}, b"abc"))
        self.assertEqual(self.read()[1], b"abc")

    def test_size_given_as_float_is_truncated(self):
        self.feed(raw_frame({"t": "file", "size": 2.9}, b"ab"))
        self.assertEqual(self.read()[1], b"ab")

    def test_size_not_a_number_is_a_connection_error(self):
        self.feed(raw_frame({"t": "file", "size": "lots"}))
        with self.assertRaisesRegex(ConnectionError, "bad data size"):
            self.read()

    def test_malformed_headers_surface_as_connection_or_value_errors(self):
        # Whatever the phone sends, read_frame must fail with an error that _handle catches.
        for header in (b"[1, 2]", b'"text"', b"42", b"null", b"true",
                       b'{"size": null}', b'{"size": [1]}', b'{"size": {"a": 1}}', b'{"size": 1e999}'):
            with self.subTest(header=header):
                a, b = socket.socketpair()
                self.addCleanup(a.close)
                self.addCleanup(b.close)
                b.settimeout(2)
                a.sendall(raw_frame(header))
                with self.assertRaises((ConnectionError, ValueError, OSError)):
                    ferryd.read_frame(b)


class Constants(unittest.TestCase):
    def test_limits_match_the_android_side(self):
        self.assertEqual(ferryd.MAX_FRAME_DATA, 64 << 20)
        self.assertEqual(ferryd.MAX_IMAGE, 25 << 20)
        self.assertEqual(ferryd.MAX_TEXT, (1 << 18) - 14)


if __name__ == "__main__":
    unittest.main()
