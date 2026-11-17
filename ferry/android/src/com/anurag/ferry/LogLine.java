package com.anurag.ferry;

final class LogLine {
    private LogLine() { }

    // "-v brief" lines look like "E/ClipboardService( 1560): ...".
    static boolean fromOtherProcess(String line, int myPid) {
        int a = line.indexOf('('), b = line.indexOf(')', a + 1);
        if (a < 0 || b < 0) return false;
        try {
            return Integer.parseInt(line.substring(a + 1, b).trim()) != myPid;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    static boolean isClipboardDenial(String line, String pkg) {
        return line.toLowerCase().contains("clipboard access to " + pkg);
    }
}
