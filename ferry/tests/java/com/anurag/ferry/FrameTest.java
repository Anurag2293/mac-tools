package com.anurag.ferry;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

final class FrameTest {
    private static byte[] encode(JSONObject h, byte[] data) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        Frame.write(new DataOutputStream(bos), h, data);
        return bos.toByteArray();
    }

    private static Frame decode(byte[] wire) throws IOException {
        return Frame.read(new DataInputStream(new ByteArrayInputStream(wire)));
    }

    private static byte[] raw(int declaredLen, String body, byte[] tail) {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        bos.write(declaredLen >>> 24);
        bos.write(declaredLen >>> 16);
        bos.write(declaredLen >>> 8);
        bos.write(declaredLen);
        bos.write(b, 0, b.length);
        if (tail != null) bos.write(tail, 0, tail.length);
        return bos.toByteArray();
    }

    static void testHeaderOnlyRoundTrip() throws Exception {
        Frame f = decode(encode(Frame.obj("t", "ping", "n", 7), null));
        T.eq("ping", f.type());
        T.eq(7, f.h.optInt("n", -1));
        T.eq(null, f.data);
    }

    static void testHeaderOnlyWireBytes() throws Exception {
        byte[] wire = encode(Frame.obj("t", "x"), null);
        byte[] expected = raw(9, "{\"t\":\"x\"}", null);
        T.eq(expected, wire);
    }

    static void testPayloadRoundTripAndSizeField() throws Exception {
        byte[] data = {0, 1, 2, (byte) 0xff, 10, 13};
        byte[] wire = encode(Frame.obj("t", "file", "name", "a.bin"), data);
        Frame f = decode(wire);
        T.eq("file", f.type());
        T.eq("a.bin", f.h.optString("name"));
        T.eq(6, f.h.optInt("size", -1));
        T.eq(data, f.data);
    }

    static void testSizeIsAddedToCallerHeader() throws Exception {
        JSONObject h = Frame.obj("t", "file");
        encode(h, new byte[3]);
        T.eq(3, h.optInt("size", -1));
    }

    static void testEmptyPayloadReadsBackAsNull() throws Exception {
        Frame f = decode(encode(Frame.obj("t", "file"), new byte[0]));
        T.eq(0, f.h.optInt("size", -1));
        T.eq(null, f.data);
    }

    static void testUnicodeHeaderLengthCountsBytes() throws Exception {
        Frame f = decode(encode(Frame.obj("t", "clip", "text", "日本語 \"quoted\" \\ \n"), null));
        T.eq("日本語 \"quoted\" \\ \n", f.h.optString("text"));
    }

    static void testTwoFramesBackToBack() throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        DataOutputStream out = new DataOutputStream(bos);
        Frame.write(out, Frame.obj("t", "a"), new byte[]{1, 2});
        Frame.write(out, Frame.obj("t", "b"), null);
        DataInputStream in = new DataInputStream(new ByteArrayInputStream(bos.toByteArray()));
        Frame a = Frame.read(in);
        Frame b = Frame.read(in);
        T.eq("a", a.type());
        T.eq(new byte[]{1, 2}, a.data);
        T.eq("b", b.type());
        T.eq(null, b.data);
    }

    static void testMissingTypeIsEmptyString() throws Exception {
        T.eq("", decode(encode(Frame.obj("k", "v"), null)).type());
    }

    static void testReadsPythonHubFrame() throws Exception {
        byte[] wire = raw(22, "{\"t\": \"ok\", \"size\": 2}", new byte[]{9, 8});
        Frame f = decode(wire);
        T.eq("ok", f.type());
        T.eq(new byte[]{9, 8}, f.data);
    }

    static void testZeroHeaderLengthRejected() {
        T.throwsIo(IOException.class, "bad header length 0", () -> decode(raw(0, "", null)));
    }

    static void testNegativeHeaderLengthRejected() {
        T.throwsIo(IOException.class, "bad header length", () -> decode(raw(-1, "", null)));
    }

    static void testHeaderLengthJustOverMaxRejected() {
        T.throwsIo(IOException.class, "bad header length", () -> decode(raw(Frame.MAX_HEADER + 1, "{}", null)));
    }

    static void testHeaderLengthAtMaxIsReadNotRejected() {
        T.throwsIo(EOFException.class, null, () -> decode(raw(Frame.MAX_HEADER, "{}", null)));
    }

    static void testMalformedJsonRejected() {
        T.throwsIo(IOException.class, "bad header json", () -> decode(raw(5, "{nope", null)));
    }

    static void testNonObjectJsonRejected() {
        T.throwsIo(IOException.class, "bad header json", () -> decode(raw(2, "[]", null)));
    }

    static void testNegativeDataSizeRejected() {
        String h = "{\"size\":-5}";
        T.throwsIo(IOException.class, "bad data size -5", () -> decode(raw(h.length(), h, null)));
    }

    static void testOversizedDataSizeRejectedBeforeAllocation() {
        String h = "{\"size\":" + (Frame.MAX_DATA + 1) + "}";
        T.throwsIo(IOException.class, "bad data size", () -> decode(raw(h.length(), h, null)));
    }

    static void testTruncatedHeaderIsEof() {
        T.throwsIo(EOFException.class, null, () -> decode(raw(50, "{\"t\":\"x\"}", null)));
    }

    static void testTruncatedPayloadIsEof() {
        String h = "{\"size\":10}";
        T.throwsIo(EOFException.class, null, () -> decode(raw(h.length(), h, new byte[4])));
    }

    static void testEmptyStreamIsEof() {
        T.throwsIo(EOFException.class, null, () -> decode(new byte[0]));
    }

    static void testObjBuildsPairsAndIgnoresTrailingKey() {
        JSONObject o = Frame.obj("a", "1", "b", 2, "dangling");
        T.eq("1", o.optString("a"));
        T.eq(2, o.optInt("b", -1));
        T.eq("", o.optString("dangling"));
    }
}
