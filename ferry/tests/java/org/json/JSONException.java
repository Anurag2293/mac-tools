package org.json;

/** Test stand-in for android.util's org.json.JSONException (checked, like the Android one). */
public class JSONException extends Exception {
    public JSONException(String message) { super(message); }
}
