#!/bin/sh
#
# libghostty ships as an XCFramework whose macOS slice has a flat layout —
# Info.plist and the binary sitting directly inside libghostty.framework. macOS
# only loads a versioned bundle (Versions/A/...) from a framework on disk, so a
# Debug build that copies the flat one produces an app that builds cleanly and
# dies at launch. This moves it into the versioned shape and re-signs it.
#
# Run as a post-build phase on TmuxGUI. The CONFIGURATION guard is carried over
# verbatim from the hand-maintained project, where this only ever ran in Debug;
# Release has not been exercised. The Versions-already-exists guard makes this a
# no-op after the first build rather than re-signing on every one.

if [ "$CONFIGURATION" = "Debug" ]; then
  framework="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Frameworks/libghostty.framework"
  if [ -f "$framework/Info.plist" ] && [ ! -d "$framework/Versions" ]; then
    mkdir -p "$framework/Versions/A/Resources"
    mv "$framework/Info.plist" "$framework/Versions/A/Resources/Info.plist"
    mv "$framework/libghostty" "$framework/Versions/A/libghostty"
    rm -rf "$framework/_CodeSignature"
    ln -sfn A "$framework/Versions/Current"
    ln -sfn Versions/Current/Resources "$framework/Resources"
    ln -sfn Versions/Current/libghostty "$framework/libghostty"
    identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$framework"
  fi
fi
