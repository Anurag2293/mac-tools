package com.anurag.ferry;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

/** Wire format: u32 header length, JSON header, then `size` raw bytes if the header has "size". */
final class Frame {
    static final int MAX_HEADER = 4 << 20;
    static final int MAX_DATA = 64 << 20;

    final JSONObject h;
    final byte[] data;

    Frame(JSONObject h, byte[] data) { this.h = h; this.data = data; }

    String type() { return h.optString("t"); }

    static JSONObject obj(Object... kv) {
        JSONObject o = new JSONObject();
        try {
            for (int i = 0; i + 1 < kv.length; i += 2) o.put((String) kv[i], kv[i + 1]);
        } catch (JSONException e) {
            throw new IllegalArgumentException(e);
        }
        return o;
    }

    static void write(DataOutputStream out, JSONObject h, byte[] data) throws IOException {
        try {
            if (data != null) h.put("size", data.length);
        } catch (JSONException e) {
            throw new IOException(e);
        }
        byte[] hb = h.toString().getBytes(StandardCharsets.UTF_8);
        out.writeInt(hb.length);
        out.write(hb);
        if (data != null) out.write(data);
        out.flush();
    }

    static Frame read(DataInputStream in) throws IOException {
        int n = in.readInt();
        if (n <= 0 || n > MAX_HEADER) throw new IOException("bad header length " + n);
        byte[] hb = new byte[n];
        in.readFully(hb);
        JSONObject h;
        try {
            h = new JSONObject(new String(hb, StandardCharsets.UTF_8));
        } catch (JSONException e) {
            throw new IOException("bad header json");
        }
        int size = h.optInt("size", 0);
        if (size < 0 || size > MAX_DATA) throw new IOException("bad data size " + size);
        byte[] d = null;
        if (size > 0) {
            d = new byte[size];
            in.readFully(d);
        }
        return new Frame(h, d);
    }
}
