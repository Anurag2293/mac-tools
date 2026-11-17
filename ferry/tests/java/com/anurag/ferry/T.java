package com.anurag.ferry;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.Comparator;

/** Tiny test runner: runs every no-arg method named test* on the given classes. */
final class T {
    static int passed, failed;

    static void run(Class<?>... classes) throws Exception {
        for (Class<?> c : classes) {
            Method[] ms = c.getDeclaredMethods();
            Arrays.sort(ms, Comparator.comparing(Method::getName));
            for (Method m : ms) {
                if (!m.getName().startsWith("test") || m.getParameterCount() != 0) continue;
                m.setAccessible(true);
                try {
                    m.invoke(null);
                    passed++;
                } catch (InvocationTargetException e) {
                    failed++;
                    System.err.println("FAILED: " + c.getSimpleName() + "." + m.getName() + ": " + e.getCause());
                }
            }
        }
        System.out.println("RESULT passed=" + passed + " failed=" + failed + " skipped=0");
        System.exit(failed == 0 ? 0 : 1);
    }

    static void eq(Object expected, Object actual) {
        if (expected instanceof byte[] && actual instanceof byte[]) {
            if (!Arrays.equals((byte[]) expected, (byte[]) actual)) {
                throw new AssertionError("expected " + Arrays.toString((byte[]) expected) + " got " + Arrays.toString((byte[]) actual));
            }
            return;
        }
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("expected [" + expected + "] got [" + actual + "]");
        }
    }

    static void isTrue(boolean cond, String what) {
        if (!cond) throw new AssertionError(what);
    }

    interface Body { void run() throws Exception; }

    static void throwsIo(Class<? extends Exception> type, String messagePart, Body body) {
        try {
            body.run();
        } catch (Exception e) {
            if (!type.isInstance(e)) throw new AssertionError("expected " + type.getSimpleName() + " but got " + e);
            if (messagePart != null && (e.getMessage() == null || !e.getMessage().contains(messagePart))) {
                throw new AssertionError("expected message containing [" + messagePart + "] but got [" + e.getMessage() + "]");
            }
            return;
        }
        throw new AssertionError("expected " + type.getSimpleName() + " but nothing was thrown");
    }
}
