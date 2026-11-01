package com.anurag.ferry;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Toast;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Invisible 1x1 activity. Android only allows clipboard reads by the focused app, so we take
 *  focus for an instant, read, send to the Mac and finish. */
public class ClipReadActivity extends Activity {
    private boolean done;
    private boolean manual;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        manual = getIntent().getBooleanExtra("manual", false);
        Window w = getWindow();
        w.setGravity(Gravity.TOP | Gravity.START);
        w.setLayout(1, 1);
        w.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL);
        new Handler(Looper.getMainLooper()).postDelayed(() -> { if (!done) finishQuietly(); }, 2500);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (!hasFocus || done) return;
        done = true;
        String msg = read();
        if (manual && msg != null) Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
        finishQuietly();
    }

    private String read() {
        LinkService svc = LinkService.instance;
        if (svc == null || !LinkService.isConnected()) return "Not connected to Mac";
        ClipboardManager cm = getSystemService(ClipboardManager.class);
        LinkService.noteOwnRead();
        ClipData clip = cm.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return "Clipboard is empty";
        ClipData.Item item = clip.getItemAt(0);
        Uri uri = item.getUri();
        if (uri != null && "com.anurag.ferry.clip".equals(uri.getAuthority())) return "Already on the Mac";
        if (uri != null) {
            String mime = getContentResolver().getType(uri);
            if (mime != null && mime.startsWith("image/")) {
                byte[] data = readAll(uri);
                if (data != null) {
                    svc.sendClipImage(mime, data);
                    return "Image sent to Mac";
                }
            }
        }
        CharSequence text = item.coerceToText(this);
        if (text == null || text.length() == 0) return "Nothing to send";
        // Password managers mark clips sensitive (ClipDescription.EXTRA_IS_SENSITIVE); the Mac
        // then pastes it as usual but doesn't show it on screen.
        android.os.PersistableBundle ex = clip.getDescription().getExtras();
        boolean sensitive = ex != null && ex.getBoolean("android.content.extra.IS_SENSITIVE", false);
        return svc.sendClipText(text.toString(), false, sensitive) ? "Sent to Mac" : "Already on the Mac";
    }

    private byte[] readAll(Uri uri) {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) return null;
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) {
                bo.write(buf, 0, n);
                if (bo.size() > Frame.MAX_DATA) return null;
            }
            return bo.toByteArray();
        } catch (IOException | SecurityException e) {
            return null;
        }
    }

    private void finishQuietly() {
        finish();
        overridePendingTransition(0, 0);
    }
}
