package com.anurag.ferry;

import android.content.Context;
import android.content.SharedPreferences;

final class Prefs {
    static final int DEFAULT_PORT = 47821;

    static SharedPreferences get(Context c) {
        return c.getSharedPreferences("link", Context.MODE_PRIVATE);
    }
    static String host(Context c) { return get(c).getString("host", ""); }
    static int port(Context c) { return get(c).getInt("port", DEFAULT_PORT); }
    static String token(Context c) { return get(c).getString("token", ""); }
    static boolean autoClip(Context c) { return get(c).getBoolean("auto_clip", true); }
    static void setAutoClip(Context c, boolean on) { get(c).edit().putBoolean("auto_clip", on).apply(); }
}
