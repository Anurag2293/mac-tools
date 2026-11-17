package org.json;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Minimal stand-in for Android's org.json.JSONObject, enough for Frame: put, optString, optInt,
 * toString and parsing flat-or-nested objects. It mimics the Android coercions Frame relies on
 * (optInt accepts numeric strings and truncates doubles; optString stringifies any value).
 */
public class JSONObject {
    private final Map<String, Object> map = new LinkedHashMap<>();

    public JSONObject() { }

    public JSONObject(String json) throws JSONException {
        Parser p = new Parser(json);
        p.skip();
        Object v = p.value();
        p.skip();
        if (p.i != json.length()) throw new JSONException("trailing data");
        if (!(v instanceof JSONObject)) throw new JSONException("Value " + json + " cannot be converted to JSONObject");
        map.putAll(((JSONObject) v).map);
    }

    public JSONObject put(String name, Object value) throws JSONException {
        if (value == null) { map.remove(name); return this; }
        if (value instanceof Double && (((Double) value).isNaN() || ((Double) value).isInfinite())) {
            throw new JSONException("Forbidden numeric value: " + value);
        }
        map.put(name, value);
        return this;
    }

    public String optString(String name) { return optString(name, ""); }

    public String optString(String name, String fallback) {
        Object v = map.get(name);
        return v == null || v == NULL ? fallback : String.valueOf(v);
    }

    public int optInt(String name, int fallback) {
        Object v = map.get(name);
        if (v instanceof Number) return ((Number) v).intValue();
        if (v instanceof String) {
            try { return (int) Double.parseDouble((String) v); } catch (NumberFormatException e) { return fallback; }
        }
        return fallback;
    }

    @Override public String toString() {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, Object> e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            quote(sb, e.getKey()).append(':');
            Object v = e.getValue();
            if (v instanceof String) quote(sb, (String) v); else sb.append(v);
        }
        return sb.append('}').toString();
    }

    private static StringBuilder quote(StringBuilder sb, String s) {
        sb.append('"');
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c)); else sb.append(c);
            }
        }
        return sb.append('"');
    }

    static final Object NULL = new Object() { @Override public String toString() { return "null"; } };

    private static final class Parser {
        final String s;
        int i;

        Parser(String s) { this.s = s; }

        void skip() { while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++; }

        Object value() throws JSONException {
            if (i >= s.length()) throw new JSONException("unexpected end");
            char c = s.charAt(i);
            if (c == '{') return object();
            if (c == '[') return array();
            if (c == '"') return string();
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            if (s.startsWith("null", i)) { i += 4; return NULL; }
            return number();
        }

        JSONObject object() throws JSONException {
            JSONObject o = new JSONObject();
            i++;
            skip();
            if (i < s.length() && s.charAt(i) == '}') { i++; return o; }
            while (true) {
                skip();
                if (i >= s.length() || s.charAt(i) != '"') throw new JSONException("expected key at " + i);
                String k = string();
                skip();
                if (i >= s.length() || s.charAt(i) != ':') throw new JSONException("expected : at " + i);
                i++;
                skip();
                Object v = value();
                o.map.put(k, v);
                skip();
                if (i >= s.length()) throw new JSONException("unterminated object");
                char c = s.charAt(i++);
                if (c == '}') return o;
                if (c != ',') throw new JSONException("expected , at " + (i - 1));
            }
        }

        Object array() throws JSONException {
            int depth = 0;
            int start = i;
            boolean inStr = false;
            for (; i < s.length(); i++) {
                char c = s.charAt(i);
                if (inStr) { if (c == '\\') i++; else if (c == '"') inStr = false; continue; }
                if (c == '"') inStr = true;
                else if (c == '[') depth++;
                else if (c == ']' && --depth == 0) { i++; return s.substring(start, i); }
            }
            throw new JSONException("unterminated array");
        }

        String string() throws JSONException {
            StringBuilder sb = new StringBuilder();
            i++;
            while (i < s.length()) {
                char c = s.charAt(i++);
                if (c == '"') return sb.toString();
                if (c != '\\') { sb.append(c); continue; }
                if (i >= s.length()) break;
                char e = s.charAt(i++);
                switch (e) {
                    case 'n': sb.append('\n'); break;
                    case 'r': sb.append('\r'); break;
                    case 't': sb.append('\t'); break;
                    case 'b': sb.append('\b'); break;
                    case 'f': sb.append('\f'); break;
                    case 'u':
                        if (i + 4 > s.length()) throw new JSONException("bad escape");
                        sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                        i += 4;
                        break;
                    default: sb.append(e);
                }
            }
            throw new JSONException("unterminated string");
        }

        Object number() throws JSONException {
            int start = i;
            while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
            if (start == i) throw new JSONException("unexpected character '" + s.charAt(i) + "' at " + i);
            String t = s.substring(start, i);
            try {
                if (t.indexOf('.') < 0 && t.indexOf('e') < 0 && t.indexOf('E') < 0) {
                    long l = Long.parseLong(t);
                    if (l == (int) l) return (int) l;
                    return l;
                }
                return Double.parseDouble(t);
            } catch (NumberFormatException e) {
                throw new JSONException("bad number " + t);
            }
        }
    }
}
