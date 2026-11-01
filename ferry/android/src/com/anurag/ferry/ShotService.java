package com.anurag.ferry;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Bitmap;
import android.hardware.HardwareBuffer;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;
import java.io.ByteArrayOutputStream;

/** Accessibility service used only for takeScreenshot(): no prompt, unlike MediaProjection. */
public class ShotService extends AccessibilityService {
    interface Callback { void done(byte[] png, String err); }

    static volatile ShotService instance;

    @Override protected void onServiceConnected() {
        instance = this;
        LinkService.start(this);
    }

    @Override public void onDestroy() {
        instance = null;
        super.onDestroy();
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) { }
    @Override public void onInterrupt() { }

    static void capture(Callback cb) {
        ShotService s = instance;
        if (s == null) {
            cb.done(null, "Ferry screenshots are off in Accessibility settings");
            return;
        }
        s.takeScreenshot(Display.DEFAULT_DISPLAY, s.getMainExecutor(), new TakeScreenshotCallback() {
            @Override public void onSuccess(ScreenshotResult r) {
                new Thread(() -> {
                    try (HardwareBuffer hb = r.getHardwareBuffer()) {
                        Bitmap hw = Bitmap.wrapHardwareBuffer(hb, r.getColorSpace());
                        if (hw == null) { cb.done(null, "could not wrap screenshot buffer"); return; }
                        Bitmap sw = hw.copy(Bitmap.Config.ARGB_8888, false);
                        hw.recycle();
                        ByteArrayOutputStream bo = new ByteArrayOutputStream(1 << 20);
                        sw.compress(Bitmap.CompressFormat.PNG, 100, bo);
                        sw.recycle();
                        cb.done(bo.toByteArray(), null);
                    } catch (RuntimeException e) {
                        cb.done(null, "screenshot encode failed: " + e);
                    }
                }, "shot").start();
            }

            @Override public void onFailure(int code) {
                cb.done(null, "takeScreenshot failed (code " + code + ")");
            }
        });
    }
}
