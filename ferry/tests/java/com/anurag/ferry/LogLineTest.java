package com.anurag.ferry;

final class LogLineTest {
    static void testOtherPid() {
        T.isTrue(LogLine.fromOtherProcess("E/ClipboardService( 1560): Denying clipboard access", 4242), "other pid");
    }

    static void testOwnPid() {
        T.isTrue(!LogLine.fromOtherProcess("E/ClipboardService( 4242): x", 4242), "own pid");
    }

    static void testPidWithoutPadding() {
        T.isTrue(LogLine.fromOtherProcess("I/ActivityTaskManager(123456): x", 1), "wide pid");
        T.isTrue(!LogLine.fromOtherProcess("I/ActivityTaskManager(7): x", 7), "narrow own pid");
    }

    static void testNoParentheses() {
        T.isTrue(!LogLine.fromOtherProcess("--------- beginning of main", 1), "banner line");
    }

    static void testNonNumericPid() {
        T.isTrue(!LogLine.fromOtherProcess("E/Tag(abc): x", 1), "non numeric");
    }

    static void testEmptyParens() {
        T.isTrue(!LogLine.fromOtherProcess("E/Tag(): x", 1), "empty");
    }

    static void testUnclosedParen() {
        T.isTrue(!LogLine.fromOtherProcess("E/Tag( 12: x", 1), "unclosed");
    }

    static void testCloseBeforeOpenIsIgnored() {
        T.isTrue(!LogLine.fromOtherProcess("x) E/Tag: no pid", 1), "close first");
    }

    static void testFirstParenGroupWinsEvenWhenMessageHasNumbers() {
        T.isTrue(!LogLine.fromOtherProcess("E/Tag( 9): see (42) now", 9), "first group is the pid");
    }

    static void testDenialMatches() {
        T.isTrue(LogLine.isClipboardDenial(
                "E/ClipboardService( 1560): Denying clipboard access to com.anurag.ferry, application is not in focus", "com.anurag.ferry"), "denial");
    }

    static void testDenialIsCaseInsensitive() {
        T.isTrue(LogLine.isClipboardDenial("DENYING CLIPBOARD ACCESS TO com.anurag.ferry", "com.anurag.ferry"), "upper-case line");
    }

    static void testDenialForOtherPackageIgnored() {
        T.isTrue(!LogLine.isClipboardDenial("Denying clipboard access to com.other.app", "com.anurag.ferry"), "other package");
    }

    static void testDenialPackageLowerCasedAsWell() {
        T.isTrue(!LogLine.isClipboardDenial("Denying clipboard access to com.anurag.ferry", "com.Anurag.Ferry"), "mixed-case pkg is never matched");
    }

    static void testDenialPrefixOfLongerPackageStillMatches() {
        T.isTrue(LogLine.isClipboardDenial("Denying clipboard access to com.anurag.ferry.debug", "com.anurag.ferry"), "prefix match");
    }

    static void testUnrelatedLine() {
        T.isTrue(!LogLine.isClipboardDenial("I/ActivityTaskManager( 1): Displayed com.anurag.ferry", "com.anurag.ferry"), "unrelated");
    }
}
