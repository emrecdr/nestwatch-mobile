package com.nestwatch.mobile

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * The one Android class this app has, and it exists for one line.
 *
 * ## Why FLAG_SECURE, on the whole activity, always
 *
 * The Screen tab renders a live picture of a child's desktop. Without this flag Android
 * captures a thumbnail of the current screen for the recents list, screen-recording apps
 * can read the window, and the content may be mirrored to a non-secure external display.
 * The most private thing this app shows would be the thing sitting in a thumbnail that
 * anyone can reach by pressing Recents on an unlocked phone. OWASP MASVS files exactly
 * this under MASVS-STORAGE, where screenshot caches are named as a leading source of
 * unintentional leaks.
 *
 * **Whole activity rather than only the Screen tab.** Toggling the flag as a tab gains and
 * loses focus races the thumbnail capture on the way out — the system snapshots around the
 * same lifecycle callbacks the toggle would hang off — so a per-tab version has a real
 * window where the frame is still capturable. One flag set once has no such window.
 *
 * The cost is that a parent can no longer screenshot any part of this app, including the
 * certificate fingerprint. That is already answered: the identity dialog renders the
 * fingerprint as `SelectableText`, so it can be copied as text, which is more useful than
 * a photograph of it anyway.
 *
 * **Not a platform-view problem here.** `mobile_scanner` 7.4.0 draws the camera through
 * `TextureRegistry.SurfaceProducer` rather than a `SurfaceView` — checked in its Android
 * source, not assumed — so the QR preview composites into Flutter's own surface and is
 * unaffected. A `SurfaceView`-based scanner would have needed checking on a device first.
 *
 * Verified by reading, not on hardware: a window flag has no headless test.
 * `test/flag_secure_test.dart` asserts this file still sets it, so it cannot be dropped
 * quietly — but only a device can show the recents thumbnail actually going blank.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }
}
