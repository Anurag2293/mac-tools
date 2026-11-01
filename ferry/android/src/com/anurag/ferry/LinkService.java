package com.anurag.ferry;

import android.app.KeyguardManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONObject;

/** Keeps one TCP connection to the Mac (over Tailscale) and routes messages both ways. */
public class LinkService extends Service {
    static final String TAG = "Ferry";
    static final String CHANNEL = "link";
    static final String ACTION_RECONNECT = "com.anurag.ferry.RECONNECT";
    static final int VERSION = 1;

    static volatile LinkService instance;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService sendQueue = Executors.newSingleThreadExecutor();
    private final Object wake = new Object();
    private volatile boolean running;
    private volatile boolean connected;
    private volatile String status = "Starting";
    private Socket sock;
    private DataOutputStream out;
    private ClipboardManager clipboard;
    private ClipWatcher watcher;
    private ConnectivityManager.NetworkCallback netCallback;
    private final ClipboardManager.OnPrimaryClipChangedListener clipListener = () -> onClipChangedHint("listener");

    // Echo suppression: what we last put on the phone clipboard ourselves.
    volatile long lastSetAt;
    volatile String lastSetText;
    // Our own clipboard reads log the same "Denying clipboard access" line if focus is lost.
    static volatile long lastOwnRead;

    static void noteOwnRead() { lastOwnRead = System.currentTimeMillis(); }
    private long lastTrigger;

    static void start(Context c) {
        try {
            c.startForegroundService(new Intent(c, LinkService.class));
        } catch (RuntimeException e) {
            Log.w(TAG, "could not start service: " + e);
        }
    }

    static boolean isConnected() {
        LinkService s = instance;
        return s != null && s.connected;
    }

    static boolean autoClipReady() {
        LinkService s = instance;
        return s != null && s.watcher.isVerified();
    }

    static void onUiVisible() {
        LinkService s = instance;
        if (s != null && Prefs.autoClip(s)) s.watcher.restartIfUnverified();
    }

    void watcherStateChanged() {
        main.post(() -> getSystemService(NotificationManager.class).notify(1, buildNotification()));
    }

    static String currentStatus() {
        LinkService s = instance;
        return s == null ? "Service not running" : s.status;
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        instance = this;
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Connection to Mac", NotificationManager.IMPORTANCE_MIN));
        startForeground(1, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);

        clipboard = getSystemService(ClipboardManager.class);
        clipboard.addPrimaryClipChangedListener(clipListener);
        watcher = new ClipWatcher(this);
        watcher.start();

        netCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network n) { kick(); }
            @Override public void onLost(Network n) { closeSocket(); kick(); }
        };
        getSystemService(ConnectivityManager.class).registerDefaultNetworkCallback(netCallback);

        running = true;
        new Thread(this::loop, "link").start();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_RECONNECT.equals(intent.getAction())) {
            closeSocket();
            kick();
        }
        return START_STICKY;
    }

    @Override public void onDestroy() {
        running = false;
        closeSocket();
        kick();
        watcher.stop();
        clipboard.removePrimaryClipChangedListener(clipListener);
        try {
            getSystemService(ConnectivityManager.class).unregisterNetworkCallback(netCallback);
        } catch (RuntimeException ignored) {
        }
        instance = null;
        super.onDestroy();
    }

    // --- connection ------------------------------------------------------------------------

    private void kick() {
        synchronized (wake) { wake.notifyAll(); }
    }

    private void sleepWake(long ms) {
        synchronized (wake) {
            try { wake.wait(ms); } catch (InterruptedException ignored) { }
        }
    }

    private void setStatus(String s, boolean isConnected) {
        if (s.equals(status) && isConnected == connected) return;
        status = s;
        connected = isConnected;
        Log.i(TAG, s);
        main.post(() -> getSystemService(NotificationManager.class).notify(1, buildNotification()));
    }

    private void loop() {
        long backoff = 1000;
        while (running) {
            String host = Prefs.host(this);
            if (host.isEmpty()) {
                setStatus("Not set up (run ferry app install on the Mac)", false);
                sleepWake(60000);
                continue;
            }
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(host, Prefs.port(this)), 10000);
                s.setTcpNoDelay(true);
                s.setKeepAlive(true);
                s.setSoTimeout(75000);  // the Mac pings every 20 s
                DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
                synchronized (this) {
                    sock = s;
                    out = new DataOutputStream(new BufferedOutputStream(s.getOutputStream(), 65536));
                    Frame.write(out, Frame.obj("t", "hello", "token", Prefs.token(this), "version", VERSION,
                            "model", Build.MODEL), null);
                }
                Frame reply = Frame.read(in);
                if (!"welcome".equals(reply.type())) throw new IOException("rejected: " + reply.h.optString("err"));
                setStatus("Connected to Mac", true);
                backoff = 1000;
                while (running) handle(Frame.read(in));
            } catch (IOException | RuntimeException e) {
                if (running) setStatus("Disconnected: " + e.getMessage(), false);
            } finally {
                closeSocket();
            }
            if (running) {
                sleepWake(backoff);
                backoff = Math.min(backoff * 2, 30000);
            }
        }
    }

    private synchronized void closeSocket() {
        connected = false;
        if (sock != null) {
            try { sock.close(); } catch (IOException ignored) { }
        }
        sock = null;
        out = null;
    }

    void send(JSONObject h, byte[] data) {
        sendQueue.execute(() -> {
            synchronized (this) {
                if (out == null) return;
                try {
                    Frame.write(out, h, data);
                } catch (IOException e) {
                    Log.w(TAG, "send failed: " + e);
                    closeSocket();
                }
            }
        });
    }

    private void handle(Frame f) {
        switch (f.type()) {
            case "ping":
                send(Frame.obj("t", "pong"), null);
                break;
            case "clip":
                setClipText(f.h.optString("text"));
                break;
            case "clip_img":
                if (f.data != null) setClipImage(f.h.optString("mime", "image/png"), f.data);
                break;
            case "shot":
                String id = f.h.optString("id");
                ShotService.capture((png, err) -> {
                    if (png != null) send(Frame.obj("t", "shot", "id", id, "ok", true), png);
                    else send(Frame.obj("t", "shot", "id", id, "ok", false, "err", err), null);
                });
                break;
            default:
                Log.w(TAG, "unknown message " + f.type());
        }
    }

    // --- clipboard: Mac -> phone ------------------------------------------------------------

    private void setClipText(String text) {
        main.post(() -> {
            lastSetText = text;
            lastSetAt = System.currentTimeMillis();
            clipboard.setPrimaryClip(ClipData.newPlainText("From Mac", text));
        });
    }

    private void setClipImage(String mime, byte[] data) {
        try {
            File dir = new File(getCacheDir(), "clip");
            dir.mkdirs();
            File[] old = dir.listFiles();
            if (old != null && old.length > 5) {
                Arrays.sort(old, (a, b) -> Long.compare(a.lastModified(), b.lastModified()));
                for (int i = 0; i < old.length - 5; i++) old[i].delete();
            }
            String ext = mime.endsWith("jpeg") ? "jpg" : "png";
            File f = new File(dir, "mac-" + System.currentTimeMillis() + "." + ext);
            try (FileOutputStream fo = new FileOutputStream(f)) { fo.write(data); }
            Uri uri = Uri.parse("content://com.anurag.ferry.clip/" + f.getName());
            main.post(() -> {
                lastSetText = null;
                lastSetAt = System.currentTimeMillis();
                clipboard.setPrimaryClip(ClipData.newUri(getContentResolver(), "Image from Mac", uri));
            });
        } catch (IOException e) {
            Log.w(TAG, "image clip failed: " + e);
        }
    }

    // --- clipboard: phone -> Mac ------------------------------------------------------------

    /** Something changed the clipboard (seen in logcat or via our listener). Read it if we can. */
    void onClipChangedHint(String source) {
        if (!Prefs.autoClip(this)) return;
        long now = System.currentTimeMillis();
        if (now - lastSetAt < 2000 || now - lastOwnRead < 1500 || now - lastTrigger < 700) return;
        lastTrigger = now;
        PowerManager pm = getSystemService(PowerManager.class);
        KeyguardManager km = getSystemService(KeyguardManager.class);
        if (!pm.isInteractive() || km.isKeyguardLocked()) return;  // Android refuses reads while locked
        main.post(() -> {
            try {
                startActivity(new Intent(this, ClipReadActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION
                                | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS));
            } catch (RuntimeException e) {
                Log.w(TAG, "could not open clipboard reader (" + source + "): " + e);
            }
        });
    }

    /** Returns false if it was an echo of what the Mac just sent us. */
    boolean sendClipText(String text, boolean share) { return sendClipText(text, share, false); }

    boolean sendClipText(String text, boolean share, boolean sensitive) {
        if (!share && text.equals(lastSetText) && System.currentTimeMillis() - lastSetAt < 10000) return false;
        send(Frame.obj("t", "clip", "text", text, "share", share, "sensitive", sensitive), null);
        return true;
    }

    void sendClipImage(String mime, byte[] data) {
        send(Frame.obj("t", "clip_img", "mime", mime), data);
    }

    void sendFile(String name, String mime, byte[] data) {
        send(Frame.obj("t", "file", "name", name, "mime", mime), data);
    }

    // --- notification -------------------------------------------------------------------------

    private Notification buildNotification() {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE);
        PendingIntent sendClip = PendingIntent.getActivity(this, 1,
                new Intent(this, ClipReadActivity.class).putExtra("manual", true)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_ferry_mono)
                .setContentTitle(connected ? "Connected to Mac" : "Not connected to Mac")
                .setContentText(!connected ? status
                        : (Prefs.autoClip(this) && ClipWatcher.canReadLogs(this) && !watcher.isVerified())
                        ? "Tap to turn on automatic clipboard (approve log access)"
                        : "Clipboard sync and screenshots are on")
                .setContentIntent(open)
                .addAction(new Notification.Action.Builder(null, "Send clipboard", sendClip).build())
                .setOngoing(true)
                .setShowWhen(false)
                .build();
    }
}
