package com.anurag.ferry;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.widget.Toast;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;

/** "Send to Mac" in the share sheet: text goes to the Mac clipboard, files to ~/Downloads. */
public class ShareActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent in = getIntent();
        LinkService svc = LinkService.instance;
        Context app = getApplicationContext();
        if (svc == null || !LinkService.isConnected()) {
            Toast.makeText(app, "Not connected to Mac", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }
        ArrayList<Uri> uris = new ArrayList<>();
        if (Intent.ACTION_SEND_MULTIPLE.equals(in.getAction())) {
            ArrayList<Uri> l = in.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri.class);
            if (l != null) uris.addAll(l);
        } else {
            Uri u = in.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
            if (u != null) uris.add(u);
        }
        String text = in.getStringExtra(Intent.EXTRA_TEXT);
        if (uris.isEmpty()) {
            if (text != null && !text.isEmpty()) {
                svc.sendClipText(text, true);
                Toast.makeText(app, "Copied on Mac", Toast.LENGTH_SHORT).show();
            }
            finish();
            return;
        }
        // Read the streams before finishing: the URI grant lives as long as this activity.
        Handler h = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            int sent = 0;
            for (Uri u : uris) {
                byte[] data = readAll(u);
                if (data == null) continue;
                svc.sendFile(displayName(u), getContentResolver().getType(u), data);
                sent++;
            }
            int n = sent;
            h.post(() -> {
                Toast.makeText(app, n == 0 ? "Could not read the shared file" :
                        (n == 1 ? "Sent to Mac" : "Sent " + n + " files to Mac"), Toast.LENGTH_SHORT).show();
                finish();
            });
        }, "share").start();
    }

    private String displayName(Uri u) {
        try (Cursor c = getContentResolver().query(u, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) return c.getString(0);
        } catch (RuntimeException ignored) {
        }
        String last = u.getLastPathSegment();
        return last != null ? last : "shared-file";
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
}
