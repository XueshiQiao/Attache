# Attaché Workspace Agent Rules

## Android Project (`AttacheAndroid`) APK Versioning & Naming Convention

When building and sending the Android APK from `/Users/joey/Code/AttacheAndroid`:

1. **App Display Name**: Always `Attache` (`app/src/main/res/values/notrans.xml`).
2. **Always Increment Build Number**:
   - Before every new APK build for the user, increment `BUILD_NUMBER` in `/Users/joey/Code/AttacheAndroid/version.properties` (`VERSION_NAME=1.0.0`, `BUILD_NUMBER=<N>`).
   - This updates Android `versionCode = 12_000_000 + BUILD_NUMBER` and `versionName = "<VERSION_NAME> (Build <BUILD_NUMBER>)"`, ensuring the Android system installer always recognizes it as an upgrade.
3. **Fixed APK Filename Format**:
   - Always name the APK file:
     `Attache-v<VERSION_NAME>-b<BUILD_NUMBER>-arm64-v8a.apk`
     (e.g., `Attache-v1.0.0-b1-arm64-v8a.apk`, `Attache-v1.0.0-b10-arm64-v8a.apk`).
   - Never use unversioned or arbitrary filenames.
4. **Push to Device Inbox**:
   - Send via `~/.local/bin/attache-send "/tmp/Attache-v<VERSION_NAME>-b<BUILD_NUMBER>-arm64-v8a.apk"`.
