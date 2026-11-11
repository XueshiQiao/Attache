# Markdown Links & Inline Images Specification (`Attaché` macOS)

## 1. Confirmed Product Requirements
1. **Strict CommonMark Syntax Compliance**:
   - **Links (`[label](destination)`)**: Rendered as styled, clickable inline links showing `label` (supports nested inline formatting such as `` [`Symbol`](file:///...) `` and `[**bold**](url)`). Note that links pointing to image filenames without `!` (e.g. `[F01-A](file:///.../F01-A.png)`) MUST render as clickable text links, NOT inline images.
   - **Inline Images (`![alt](destination)`)**: ONLY standard Markdown image syntax prefixed with unescaped `!` renders the image inline (in both body `MarkdownTextView` blocks and `TableGridView` cells).
   - **Malformed Syntax Stays Literal**: Broken brackets/parentheses, whitespace between `]` and `(`, unescaped ASCII spaces/control characters in bare `(destination)` (without `<...>`), or backslash-escaped `\[` / `\!` MUST remain literal text.
2. **Local & Web Link Click Behavior**:
   - **Local sessions (`pathsAreLocal == true`)**:
     - Web URLs (`http://`, `https://`, `mailto:`, etc.) open via `NSWorkspace.shared.open(url)`.
     - Local files and directories (`file:///...`, `/abs/path`, `~/path`, `cwd`-relative `./rel` or `docs/foo.png`, including `#L10-L20` line fragments, `%20`/CJK percent-encoding, unencoded Unicode, and `<file:///path with spaces.png>`) open **directly in macOS default application** via `NSWorkspace.shared.open(URL(fileURLWithPath: resolvedPath))` (e.g. `.png` opens in Preview, `.swift`/`.md` opens in default editor, folders open in Finder).
     - Missing local targets surface a non-intrusive notice in `ChatPaneView`.
   - **Remote SSH sessions (`pathsAreLocal == false`)**:
     - NEVER probe local `FileManager` or `NSImage(contentsOfFile:)`.
     - Route clicks through `RemoteLinkResolver` + `RemoteOpener` (web URLs open locally; remote files/dirs open via `RemoteOpener`).

## 2. Architecture & Implementation Rules
1. **Pure Parser (`Attache/UI/ConversationMarkdown.swift`)**:
   - Keep `ConversationMarkdown` 100% pure/synchronous with zero file/network I/O so caching and `Tools/MarkdownCheck` standalone compilation remain intact.
   - Emit `.link: destination as NSString` (`NSString` preserves relative paths, `#L10`, and unencoded CJK without `NSURL` failure) + accent color + single underline.
   - Emit `.markdownImage` custom attribute on `[alt]` fallback text (plus `.link: destination as NSString`, unless overridden by an outer wrapping link `[![alt](img)](href)`).
   - Keep `visibleText`, `firstLine`, and `ChatFold.firstLine` consistent with the exact CommonMark link/image scanner.
2. **Unified Table Cell Rendering (`Attache/UI/MarkdownTable.swift`)**:
   - Unify `TableGridView` cell inline parsing with `ConversationMarkdown.inline`.
   - Construct cell `NSTextView`s using explicit **TextKit 1** (`NSTextStorage` + `NSLayoutManager` + `NSTextContainer`) so `NSTextAttachmentCell` sizing/drawing works reliably on macOS 14+, and wire `delegate` + `linkTextAttributes` (`.pointingHand` cursor).
   - Ensure `MarkdownBlocks.cells` ignores `|` inside backtick code spans and CommonMark `<...>` destinations.
3. **Async Image Hydration & AppKit Drawing (`MarkdownTextView.swift` & `MarkdownTable.swift`)**:
   - Shared `NSCache` + background loader (`file://`, `/`, `~/`, `cwd`-relative when `pathsAreLocal == true`; `http(s)://` and `data:image/...` always).
   - Subclass `NSTextAttachmentCell` with proportional width-clamping (`maxWidth: 520` / `maxHeight: 360` in body; `maxWidth: 220` / `maxHeight: 180` in table cells, further clamped to available line fragment width).
   - **CRITICAL AppKit Rule**: Draw `NSImage` with `respectFlipped: true` (and `.high` interpolation + rounded clip if appropriate) so images are NEVER upside-down inside flipped `NSTextView`s.
   - Preserve existing paragraph/guide/link attributes on the `\u{FFFC}` attachment character when replacing `[alt]`, then invalidate intrinsic content size / table row heights on `@MainActor`.
4. **Verification**:
   - Standalone unit suites: `Tools/MarkdownCheck/main.swift` and `Tools/LinkTargetCheck/main.swift`.
   - Full target build: `xcodebuild -project Attache.xcodeproj -scheme Attache -configuration Debug ... build`.
