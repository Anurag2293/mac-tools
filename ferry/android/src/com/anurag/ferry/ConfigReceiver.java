package com.anurag.ferry;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/** Set by `ferry app install` over adb; protected so only the shell user can send it. */
public class ConfigReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        SharedPreferences.Editor e = Prefs.get(c).edit();
        if (i.hasExtra("host")) e.putString("host", i.getStringExtra("host"));
        if (i.hasExtra("port")) e.putInt("port", i.getIntExtra("port", Prefs.DEFAULT_PORT));
        if (i.hasExtra("token")) e.putString("token", i.getStringExtra("token"));
        if (i.hasExtra("auto_clip")) e.putBoolean("auto_clip", i.getBooleanExtra("auto_clip", true));
        e.commit();
        LinkService.start(c);
        try {
            c.startService(new Intent(c, LinkService.class).setAction(LinkService.ACTION_RECONNECT));
        } catch (RuntimeException ignored) {
        }
        setResultCode(1);
        setResultData("configured host=" + Prefs.host(c) + " port=" + Prefs.port(c));
    }
}
