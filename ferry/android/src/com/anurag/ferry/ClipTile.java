package com.anurag.ferry;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** Quick Settings tile: one tap sends the current clipboard to the Mac. */
public class ClipTile extends TileService {
    @Override public void onStartListening() {
        Tile t = getQsTile();
        if (t == null) return;
        t.setState(LinkService.isConnected() ? Tile.STATE_INACTIVE : Tile.STATE_UNAVAILABLE);
        t.setSubtitle(LinkService.isConnected() ? "to Mac" : "Mac offline");
        t.updateTile();
    }

    @Override public void onClick() {
        Intent i = new Intent(this, ClipReadActivity.class).putExtra("manual", true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 2, i,
                    PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT));
        } else {
            startActivityAndCollapse(i);
        }
    }
}
