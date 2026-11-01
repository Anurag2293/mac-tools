package com.anurag.ferry;

import android.content.Context;
import android.content.pm.PackageManager;
import android.util.Log;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;

/**
 * Android 10+ won't let a background app read the clipboard, but when the clipboard changes the
 * system tries to notify our listener, refuses, and logs "Denying clipboard access to <pkg>".
 * With READ_LOGS (granted once over adb) we watch for that line and treat it as "clipboard changed".
 *
 * Android 13+ additionally asks the user before an app may read other processes' logs, and only
 * asks while the app is in the foreground; a logcat started from the background silently gets
 * just our own lines. So the reader is (re)started from MainActivity until we have seen a line
 * from another process ("verified"); one approval lasts as long as the logcat process does.
 */
final class ClipWatcher {
    private final LinkService svc;
    private final int myPid = android.os.Process.myPid();
    private volatile boolean on;
    private volatile boolean verified;
    private volatile Process proc;
    private volatile long procStartedAt;
    private volatile boolean procFromUi, uiAsked;
    private Thread thread;
    private final Object kick = new Object();

    ClipWatcher(LinkService svc) { this.svc = svc; }

    static boolean canReadLogs(Context c) {
        return c.checkSelfPermission("android.permission.READ_LOGS") == PackageManager.PERMISSION_GRANTED;
    }

    boolean isVerified() { return verified; }

    synchronized void start() {
        if (!canReadLogs(svc)) {
            Log.i(LinkService.TAG, "READ_LOGS not granted; automatic phone->Mac clipboard is off");
            return;
        }
        if (thread != null && thread.isAlive()) return;
        on = true;
        thread = new Thread(this::run, "clipwatch");
        thread.start();
    }

    /** Called when our UI is in front: a fresh logcat now can get the consent dialog. */
    void restartIfUnverified() {
        if (verified) return;
        start();
        // Closing the consent dialog resumes our activity too; killing the logcat that was just
        // approved would throw the approval away. Give a fresh one time to see other lines first.
        if (procFromUi && System.currentTimeMillis() - procStartedAt < 20000) return;
        uiAsked = true;
        Process p = proc;
        if (p != null) p.destroy();   // run() starts a new one right away
        synchronized (kick) { kick.notifyAll(); }
    }

    void stop() {
        on = false;
        Process p = proc;
        if (p != null) p.destroy();
        synchronized (kick) { kick.notifyAll(); }
    }

    private void run() {
        String needle = "clipboard access to " + svc.getPackageName();
        while (on) {
            verified = false;
            svc.watcherStateChanged();
            try {
                proc = new ProcessBuilder("logcat", "-T", "1", "-v", "brief",
                        "ClipboardService:*", "ActivityTaskManager:I", "*:S")
                        .redirectErrorStream(true).start();
                procStartedAt = System.currentTimeMillis();
                procFromUi = uiAsked;
                uiAsked = false;
                try (BufferedReader r = new BufferedReader(new InputStreamReader(proc.getInputStream()))) {
                    String line;
                    while (on && (line = r.readLine()) != null) {
                        if (!verified && fromOtherProcess(line)) {
                            verified = true;
                            Log.i(LinkService.TAG, "log access approved; automatic clipboard is on");
                            svc.watcherStateChanged();
                        }
                        if (line.toLowerCase().contains(needle)) svc.onClipChangedHint("logcat");
                    }
                }
            } catch (IOException e) {
                Log.w(LinkService.TAG, "logcat failed: " + e);
            }
            if (on) {
                synchronized (kick) {
                    try { kick.wait(5000); } catch (InterruptedException ignored) { }
                }
            }
        }
    }

    // "-v brief" lines look like "E/ClipboardService( 1560): ...".
    private boolean fromOtherProcess(String line) {
        int a = line.indexOf('('), b = line.indexOf(')', a + 1);
        if (a < 0 || b < 0) return false;
        try {
            return Integer.parseInt(line.substring(a + 1, b).trim()) != myPid;
        } catch (NumberFormatException e) {
            return false;
        }
    }
}
