# Attaché Workspace Agent Rules

## Android Project (`AttacheAndroid`) APK Versioning & Naming Convention

When building and sending the Android APK from `/Users/joey/Code/AttacheAndroid`:

1. **App Display Name & Package ID**:
   - Display Name: Always `Attaché` (`app/src/main/res/values/notrans.xml`).
   - Package ID (`applicationId`): `me.xueshi.attache`.
2. **Always Increment Version & Build Number**:
   - Before every new APK build for the user, update `/Users/joey/Code/AttacheAndroid/version.properties` (`VERSION_NAME=<MAJOR>.<MINOR>.<PATCH>`, `BUILD_NUMBER=<N>`):
     - Always increment `BUILD_NUMBER` by 1.
     - For normal feature or UX updates, also increment the **minor** version by 1 (`1.1.0` -> `1.2.0` -> `1.3.0` -> `1.4.0`, resetting patch to `0`).
     - For tiny bug-fix-only builds, increment the **patch** (bug fix) version by 1 (`1.1.1`, `1.1.2`, etc.).
   - This updates Android `versionCode = 12_000_000 + BUILD_NUMBER` and `versionName = "<VERSION_NAME> (Build <BUILD_NUMBER>)"`, ensuring the Android system installer always recognizes it as an upgrade.
3. **Fixed APK Filename Format**:
   - Always name the APK file:
     `Attache-v<VERSION_NAME>-b<BUILD_NUMBER>-arm64-v8a.apk`
     (e.g., `Attache-v1.1.0-b36-arm64-v8a.apk`, `Attache-v1.2.0-b37-arm64-v8a.apk`).
   - Never use unversioned or arbitrary filenames.
4. **Push to Device Inbox**:
   - Send via `~/.local/bin/attache-send "/tmp/Attache-v<VERSION_NAME>-b<BUILD_NUMBER>-arm64-v8a.apk"`.
