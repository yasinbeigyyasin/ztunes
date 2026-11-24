# Ztunes Android — browser-session sign-in build

The Android app packages the full SvelteKit UI in a local WebView and uses the shared Rust music core for search, account authentication, library access, and playback. It does not launch the YouTube Music app. Google blocks embedded Android WebViews for sign-in, so Android uses a native, obscured import sheet for a YouTube Music browser-session Cookie header.

## Android sign-in flow

1. In Ztunes, choose **Connect account** / **Paste browser session**.
2. On a computer, sign in to `music.youtube.com` in Chrome or Edge. In DevTools → Network, reload, select a `/youtubei/v1/browse` request, and copy its `Cookie` request header.
3. Paste the header into Ztunes' native sign-in sheet. The field is excluded from autofill and saved view state, disables personalized keyboard learning, and the dialog uses Android's secure-window flag. The cookie is sent directly from native Kotlin to the Rust account API; it is never placed in the WebView/JavaScript layer.
4. Ztunes validates the session with YouTube Music before completing sign-in. A multi-channel account continues to the shared channel picker. Cookies are encrypted with AES-GCM under a non-exportable Android Keystore key before being persisted; sign-in fails closed if secure storage cannot be initialized or written.

A cookie is equivalent to a password. Do not share it, paste it into chat, or use a browser session you are not authorized to use. Sessions expire or can be revoked; Android listens for session rejection and prompts the user to import a fresh session. The native importer does not open a browser or the YouTube Music app itself; the user performs the browser sign-in and explicit transfer separately.

## Build

Requirements: Node.js 22, pnpm 10.8.1, Java 17, Android SDK/NDK 27.2.12479018, Rust with the `aarch64-linux-android` target, `cargo-ndk`, and the pinned ARM64 libmpv package described in `.github/workflows/build-ztunes-android.yml`.

From the repository root:

```bash
bash android/scripts/build-web-ui.sh
bash android/scripts/build-native.sh
# Then from the repository root:
gradle -p android assembleDebug --no-daemon
```

`build-web-ui.sh` installs the lockfile-pinned UI dependencies, runs the UI self-checks and Svelte diagnostics, then runs the static SvelteKit build with `ZTUNES_ANDROID_WEBVIEW=1`. The 45 self-checks require Node.js 22. Gradle packages `ui/build` as Android assets. `build-native.sh` cross-compiles the shared Rust core and generates the UniFFI Kotlin bindings under `android/app/src/main/generated`.

The manual GitHub Actions workflow performs the UI, native and APK builds and uploads an ARM64 debug APK. Debug APKs are for testing, not Play Store release.

## Verification status and limits

UI validation passed under Node.js 22.23.5: all 45 self-checks passed, Svelte diagnostics reported 0 errors and 0 warnings, and the static `ui/build/index.html` bundle was generated. The browser-cookie route is new and has **not** been verified end-to-end on an Android device. A successful compile would not prove Google accepts a particular session, that every library category loads, or that playback survives suspension and re-login. Do not treat this source change as a verified sign-in fix or use another APK as a fix until the full device flow is tested: first import a fresh cookie, verify library categories and account/channel identity, play tracks, force-stop/relaunch, then test session expiry/re-import. Android Keystore persistence, generated UniFFI bindings, WebView bridge behavior, native compilation, and Gradle packaging remain unverified and require the Android/Rust toolchains.

The app targets ARM64 devices on Android 8.0/API 26 or later. Its native build uses the pinned third-party libmpv Android package; review its provenance, GPL obligations, and the bundled notices before distribution. No foreground media service, notification/lock-screen controls, or background-playback guarantee is added by this sign-in work.
