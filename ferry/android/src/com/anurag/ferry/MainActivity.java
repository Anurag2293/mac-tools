package com.anurag.ferry;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

/** Status and settings screen. Built in code so the build needs no AndroidX or layout XML. */
public class MainActivity extends Activity {
    // Palette
    static final int BG = 0xFF0E1113;
    static final int CARD = 0xFF171B1F;
    static final int STROKE = 0xFF232A30;
    static final int TEXT = 0xFFEDEFF1;
    static final int MUTED = 0xFF9AA4AD;
    static final int ACCENT = 0xFF19B394;
    static final int WARN = 0xFFF2A93B;
    static final int BAD = 0xFFE5534B;

    private final Handler h = new Handler(Looper.getMainLooper());
    private float dp;

    private View statusDot;
    private TextView statusTitle, statusDetail;
    private Switch autoSwitch;
    private TextView autoState, clipPreview;
    private TextView shotState;
    private View shotButton;
    private LinearLayout checks;

    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); h.postDelayed(this, 1000); }
    };

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinkService.start(this);
        dp = getResources().getDisplayMetrics().density;
        getWindow().getDecorView().setBackgroundColor(BG);
        getWindow().setNavigationBarColor(Color.TRANSPARENT);
        getWindow().setStatusBarColor(Color.TRANSPARENT);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(px(20), px(12), px(20), px(28));

        col.addView(header());
        col.addView(statusCard());
        col.addView(clipboardCard());
        col.addView(screenshotCard());
        col.addView(permissionsCard());

        TextView foot = text("Also anywhere on the phone: the Send to Mac tile in Quick Settings, the button on Ferry's notification, or Share › Send to Mac.", 13, MUTED);
        foot.setPadding(px(6), px(8), px(6), 0);
        col.addView(foot);

        ScrollView sv = new ScrollView(this);
        sv.setFillViewport(true);
        sv.addView(col);
        sv.setOnApplyWindowInsetsListener((v, insets) -> {
            Insets s = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            v.setPadding(s.left, s.top, s.right, s.bottom);
            return WindowInsets.CONSUMED;
        });
        setContentView(sv);
    }

    // --- sections ------------------------------------------------------------------------------

    private View header() {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(px(4), px(16), 0, px(20));

        FrameLayout logo = new FrameLayout(this);
        GradientDrawable bg = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{0xFF0B4A4C, 0xFF14A37F});
        bg.setCornerRadius(px(16));
        logo.setBackground(bg);
        ImageView glyph = new ImageView(this);
        glyph.setImageResource(R.drawable.ic_ferry_fg);
        glyph.setScaleType(ImageView.ScaleType.FIT_CENTER);
        logo.addView(glyph, new FrameLayout.LayoutParams(px(76), px(76), Gravity.CENTER));
        logo.setClipToOutline(true);
        row.addView(logo, new LinearLayout.LayoutParams(px(56), px(56)));

        LinearLayout titles = new LinearLayout(this);
        titles.setOrientation(LinearLayout.VERTICAL);
        titles.setPadding(px(14), 0, 0, 0);
        TextView name = text("Ferry", 28, TEXT);
        name.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        titles.addView(name);
        titles.addView(text("Clipboard, files and screenshots between this phone and your Mac", 13, MUTED));
        row.addView(titles, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        return row;
    }

    private View statusCard() {
        LinearLayout card = card();
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        statusDot = new View(this);
        row.addView(statusDot, new LinearLayout.LayoutParams(px(12), px(12)));
        LinearLayout t = new LinearLayout(this);
        t.setOrientation(LinearLayout.VERTICAL);
        t.setPadding(px(14), 0, px(8), 0);
        statusTitle = text("", 18, TEXT);
        statusTitle.setTypeface(Typeface.DEFAULT_BOLD);
        statusDetail = text("", 13, MUTED);
        t.addView(statusTitle);
        t.addView(statusDetail);
        row.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        row.addView(smallButton("Reconnect", v -> startService(
                new Intent(this, LinkService.class).setAction(LinkService.ACTION_RECONNECT))));
        card.addView(row);
        return card;
    }

    private View clipboardCard() {
        LinearLayout card = card();
        card.addView(sectionTitle("Clipboard"));

        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout t = new LinearLayout(this);
        t.setOrientation(LinearLayout.VERTICAL);
        t.addView(text("Send copies to the Mac automatically", 16, TEXT));
        autoState = text("", 13, MUTED);
        t.addView(autoState);
        row.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        autoSwitch = new Switch(this);
        autoSwitch.setChecked(Prefs.autoClip(this));
        int[][] states = {{android.R.attr.state_checked}, {}};
        autoSwitch.setThumbTintList(new ColorStateList(states, new int[]{Color.WHITE, 0xFFB8C0C7}));
        autoSwitch.setTrackTintList(new ColorStateList(states, new int[]{ACCENT, 0xFF39424A}));
        autoSwitch.setOnCheckedChangeListener((v, on) -> {
            Prefs.setAutoClip(this, on);
            if (on) LinkService.onUiVisible();
            refresh();
        });
        row.addView(autoSwitch);
        card.addView(row);

        View primary = primaryButton("Send clipboard now", v -> startActivity(
                new Intent(this, ClipReadActivity.class).putExtra("manual", true)));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, px(48));
        lp.topMargin = px(16);
        card.addView(primary, lp);

        clipPreview = text("", 13, MUTED);
        clipPreview.setPadding(0, px(12), 0, 0);
        clipPreview.setMaxLines(2);
        clipPreview.setEllipsize(TextUtils.TruncateAt.END);
        card.addView(clipPreview);
        return card;
    }

    private View screenshotCard() {
        LinearLayout card = card();
        card.addView(sectionTitle("Live screenshots"));
        card.addView(text("Your Mac can capture this screen with ferry shot, even when the phone is locked.", 14, MUTED));
        shotState = text("", 14, TEXT);
        shotState.setPadding(0, px(10), 0, 0);
        card.addView(shotState);
        shotButton = smallButton("Open Accessibility settings", v -> startActivity(
                new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = px(10);
        card.addView(shotButton, lp);
        return card;
    }

    private View permissionsCard() {
        LinearLayout card = card();
        card.addView(sectionTitle("Setup"));
        checks = new LinearLayout(this);
        checks.setOrientation(LinearLayout.VERTICAL);
        card.addView(checks);
        return card;
    }

    // --- state -------------------------------------------------------------------------------

    private void refresh() {
        boolean connected = LinkService.isConnected();
        String host = Prefs.host(this);
        dot(statusDot, connected ? ACCENT : (host.isEmpty() ? BAD : WARN));
        statusTitle.setText(connected ? "Connected to your Mac" : (host.isEmpty() ? "Not set up" : "Connecting…"));
        statusDetail.setText(connected ? host + " · over Tailscale"
                : host.isEmpty() ? "Run ferry app install on the Mac" : LinkService.currentStatus());

        boolean logs = ClipWatcher.canReadLogs(this);
        boolean ready = LinkService.autoClipReady();
        if (!autoSwitch.isChecked()) setState(autoState, "Off. Use the button, the tile or the notification.", MUTED);
        else if (!logs) setState(autoState, "Needs setup: run ferry app install on the Mac", WARN);
        else if (!ready) setState(autoState, "Waiting for approval. Tap Allow if Android asks; confirms on your next copy.", WARN);
        else setState(autoState, "On", ACCENT);

        clipPreview.setText("On this phone: " + clipText());

        boolean shots = ShotService.instance != null;
        setState(shotState, shots ? "✓  Ready" : "Off: turn on Ferry screenshots in Accessibility", shots ? ACCENT : WARN);
        shotButton.setVisibility(shots ? View.GONE : View.VISIBLE);

        PowerManager pm = getSystemService(PowerManager.class);
        checks.removeAllViews();
        check("Log access for automatic clipboard", logs && ready, logs ? (ready ? null : "approve when asked") : "ferry app install");
        check("Display over other apps", Settings.canDrawOverlays(this), "ferry app install");
        check("Accessibility service", shots, "Accessibility settings");
        check("Unrestricted battery", pm.isIgnoringBatteryOptimizations(getPackageName()), "ferry app install");
    }

    private String clipText() {
        if (!hasWindowFocus()) return "…";
        LinkService.noteOwnRead();
        ClipData c = getSystemService(ClipboardManager.class).getPrimaryClip();
        if (c == null || c.getItemCount() == 0) return "(empty)";
        ClipData.Item it = c.getItemAt(0);
        if (it.getUri() != null && it.getText() == null) {
            String type = getContentResolver().getType(it.getUri());
            return type != null && type.startsWith("image/") ? "an image" : "a file";
        }
        CharSequence t = it.coerceToText(this);
        return t == null || t.length() == 0 ? "(empty)" : t.toString().replace('\n', ' ');
    }

    private void check(String label, boolean ok, String fix) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, px(6), 0, px(6));
        TextView mark = text(ok ? "✓" : "!", 15, ok ? ACCENT : WARN);
        mark.setTypeface(Typeface.DEFAULT_BOLD);
        mark.setGravity(Gravity.CENTER);
        row.addView(mark, new LinearLayout.LayoutParams(px(22), ViewGroup.LayoutParams.WRAP_CONTENT));
        TextView l = text(label, 14, TEXT);
        l.setPadding(px(8), 0, 0, 0);
        row.addView(l, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        if (!ok && fix != null) row.addView(text(fix, 12, MUTED));
        checks.addView(row);
    }

    // --- widgets -----------------------------------------------------------------------------

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(px(18), px(16), px(18), px(16));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD);
        bg.setCornerRadius(px(20));
        bg.setStroke(px(1), STROKE);
        c.setBackground(bg);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = px(12);
        c.setLayoutParams(lp);
        return c;
    }

    private TextView sectionTitle(String s) {
        TextView t = text(s.toUpperCase(), 12, MUTED);
        t.setLetterSpacing(0.08f);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, 0, 0, px(10));
        return t;
    }

    private TextView text(String s, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setLineSpacing(0, 1.1f);
        return t;
    }

    private View primaryButton(String label, View.OnClickListener l) {
        TextView b = text(label, 16, 0xFF06231D);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setGravity(Gravity.CENTER);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(ACCENT);
        shape.setCornerRadius(px(14));
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), shape, null));
        b.setOnClickListener(l);
        return b;
    }

    private View smallButton(String label, View.OnClickListener l) {
        TextView b = text(label, 14, ACCENT);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setPadding(px(14), px(8), px(14), px(8));
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(Color.TRANSPARENT);
        shape.setCornerRadius(px(12));
        shape.setStroke(px(1), 0xFF2C4A44);
        GradientDrawable mask = new GradientDrawable();
        mask.setColor(Color.WHITE);
        mask.setCornerRadius(px(12));
        b.setBackground(new RippleDrawable(ColorStateList.valueOf(0x2219B394), shape, mask));
        b.setOnClickListener(l);
        return b;
    }

    private void dot(View v, int color) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(color);
        GradientDrawable halo = new GradientDrawable();
        halo.setShape(GradientDrawable.OVAL);
        halo.setColor(color & 0x40FFFFFF);
        LayerDrawable ld = new LayerDrawable(new android.graphics.drawable.Drawable[]{halo, d});
        ld.setLayerInset(1, px(2), px(2), px(2), px(2));
        v.setBackground(ld);
    }

    private void setState(TextView t, String s, int color) {
        t.setText(s);
        t.setTextColor(color);
    }

    private int px(float v) { return Math.round(v * dp); }

    @Override protected void onResume() {
        super.onResume();
        LinkService.onUiVisible();
        h.post(tick);
    }

    @Override protected void onPause() {
        super.onPause();
        h.removeCallbacks(tick);
    }
}
