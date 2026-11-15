//! `attache-cli mermaid --source <base64> [--dark] [--scale <n>] [--inline]`:
//! draws a Mermaid diagram as a PNG.
//!
//! Here rather than in either client so that the phone and the desktop show
//! the same picture, from one renderer neither has to carry — and as pixels,
//! because neither client may bring in a web view to draw SVG with (the
//! owner's ruling, 2026-11-15; the repository's CLAUDE.md has it). merman's
//! SVG is styled by a `<style>` element, which AppKit's `NSImage` ignores:
//! it drew every edge of a flowchart as a solid black shape. So the drawing
//! happens here, with resvg, and what leaves this program is a picture any
//! image view shows.
//!
//! **The text is drawn with this host's fonts**, which is what pixels cost.
//! Named files rather than a scan of the system: merman's own scan stopped
//! at its limits on a Mac with an ordinary set of fonts ("system-cmap-bytes",
//! 16.8 MB against 16 MB), and reading every font on the machine for each
//! diagram would be slow if it had not. One file is used, the system's
//! Chinese font, with a list of others to fall back to (`CJK_FONTS`); a host with neither is told so rather than
//! handed a picture with boxes for words. The same fonts measure the text
//! and paint it, so a label fits the box it was laid out in.
//!
//! Prints one line, always, when the arguments were readable:
//! `{"mermaid":true,"width","height","scale","path"}` (`"png"`, base64, in
//! place of `path` under `--inline`) or `{"mermaid":false,"why"}`. `width`
//! and `height` are in points: the PNG is `scale` times that in pixels. The
//! difference between a refusal and no line at all is the point: "this
//! source cannot be drawn" is true forever and a client keeps it, while a
//! command that never answered is asked again. A panic inside the renderer
//! therefore answers too — the release build aborts on panic, so the hook is
//! the only place left to say anything.
//!
//! `path` is a file under this program's state folder, for the client that
//! fetches files from the host (the phone, over its transfer connection);
//! `--inline` is for the one that reads this program's output directly (the
//! desktop). Pictures there are named by what they are of, so the same
//! diagram asked for twice is drawn once, and are removed after a week.
//!
//! The source is a reply an agent wrote, so nothing in it is trusted: the
//! parse is strict, and the render has a deadline and merman's limits on
//! what a diagram may cost.

use crate::{fsutil, paths};
use merman::svg::export::{NativeFontLimits, NativeFontOptions, RasterOptions};
use merman::svg::RenderResourcePolicy;
use merman::{
    MermaidEngine, OperationControl, ParseOptions, PngRequest, RenderOutput, RenderRequest,
    Renderer, SourcePresentationConfig, SvgEnvironment, SvgRequest,
};
use serde_json::json;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// A diagram somebody drew by hand is a few kilobytes. This is what an
/// argument can carry everywhere it travels, with room to spare.
const MAX_SOURCE: usize = 64 * 1024;

/// Reading the fonts takes about 75 ms and a six-node flowchart about 350
/// (measured on an M-series Mac, at scale 2). Past this it is not a diagram
/// anyone meant to draw.
const DEADLINE: Duration = Duration::from_secs(8);

const KEEP: Duration = Duration::from_secs(7 * 24 * 3600);

/// One face draws everything, Latin included: the system's own Chinese
/// font, PingFang on a Mac (the owner's choice, 2026-11-15).
///
/// One and not a Latin face beside it, because the two cannot share a line.
/// When the first face lacks a glyph, usvg shapes the whole run again in the
/// fallback, and if the fallback has every glyph it takes the whole run from
/// it. Every CJK font has Latin letters, so with Menlo first "1. /tmp/a.json"
/// was Menlo and "2. 本机 history.jsonl" on the next line was all PingFang —
/// two Latin faces in one box. Measured, and shown to the owner, who chose
/// one face throughout.
///
/// **The order is the fallback, and it is the owner's question answered:
/// what draws a diagram on a machine with no PingFang.** PingFang where
/// current macOS keeps it (`pingfang_asset`), then where older macOS did,
/// then Hiragino Sans GB and STHeiti, which every Mac has under a fixed path
/// and which are the closest in look; then Noto Sans CJK, which is what a
/// Linux machine with Chinese fonts has.
const CJK_FONTS: &[&str] = &[
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
];
/// The last resort, for a machine with no Chinese font at all: a diagram in
/// English is still drawn. Chinese in it has no glyphs to be drawn with.
const LATIN_FONTS: &[&str] = &[
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
];
/// The families those files hold, in the same order.
const FONT_FAMILY: &str = "PingFang SC, Hiragino Sans GB, Heiti SC, Noto Sans CJK SC, Helvetica, DejaVu Sans, Noto Sans, sans-serif";

/// PingFang where current macOS keeps it: not in `/System/Library/Fonts`
/// but in a font asset folder whose name is a hash, so it is looked for
/// rather than named (measured on macOS 27:
/// `AssetsV2/com_apple_MobileAsset_Font8/<hash>.asset/AssetData/PingFang.ttc`).
fn pingfang_asset() -> Option<PathBuf> {
    let assets = Path::new("/System/Library/AssetsV2");
    let mut found = Vec::new();
    for kind in std::fs::read_dir(assets).ok()?.flatten() {
        if !kind.file_name().to_string_lossy().starts_with("com_apple_MobileAsset_Font") {
            continue;
        }
        for asset in std::fs::read_dir(kind.path()).into_iter().flatten().flatten() {
            let file = asset.path().join("AssetData/PingFang.ttc");
            if file.is_file() {
                found.push(file);
            }
        }
    }
    // More than one is two versions of the same font; any order will do as
    // long as it is the same one every time.
    found.sort();
    found.pop()
}

/// PingFang.ttc alone is 78 MB, past merman's default of 64 for all fonts
/// together.
const MAX_FONT_BYTES: usize = 192 * 1024 * 1024;

struct Picture {
    png: Vec<u8>,
    /// In points.
    width: f64,
    height: f64,
}

pub fn run(args: &[String]) -> i32 {
    let usage = || {
        eprintln!("Usage: attache-cli mermaid --source <base64> [--dark] [--scale <1-4>] [--inline]");
        2
    };
    let mut source = None;
    let mut dark = false;
    let mut inline = false;
    let mut scale = 2u8;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--source" => source = it.next(),
            "--dark" => dark = true,
            "--inline" => inline = true,
            "--scale" => match it.next().and_then(|s| s.parse::<u8>().ok()) {
                Some(n @ 1..=4) => scale = n,
                _ => return usage(),
            },
            _ => return usage(),
        }
    }
    let Some(b64) = source else {
        return usage();
    };
    let Some(source) = crate::input::decode(b64).and_then(|b| String::from_utf8(b).ok()) else {
        eprintln!("attache-cli mermaid: the source is not base64 of UTF-8 text");
        return 2;
    };
    std::panic::set_hook(Box::new(|_| {
        println!("{}", refusal("the renderer failed on this diagram"));
    }));
    println!("{}", answer(&source, dark, scale, inline));
    0
}

fn refusal(why: &str) -> serde_json::Value {
    json!({ "mermaid": false, "why": why })
}

pub fn answer(source: &str, dark: bool, scale: u8, inline: bool) -> serde_json::Value {
    if source.len() > MAX_SOURCE {
        return refusal("the diagram is too long");
    }
    let file = folder().join(name(source, dark, scale));
    if !inline {
        sweep(&folder());
    }
    let kept = std::fs::read(&file).ok().and_then(|png| picture(png, scale));
    let picture = match kept {
        Some(picture) => picture,
        None => match render(source, dark, scale) {
            Ok(picture) => picture,
            Err(why) => return refusal(&why),
        },
    };
    let mut answer = json!({
        "mermaid": true,
        "width": picture.width,
        "height": picture.height,
        "scale": scale,
    });
    if inline {
        answer["png"] = json!(base64(&picture.png));
    } else {
        // Written even when it was just read: the write is what makes the
        // file a week younger, and a picture still being asked for is not
        // one to remove.
        if let Err(e) = std::fs::create_dir_all(folder()).and_then(|_| fsutil::write_atomic(&file, &picture.png)) {
            return refusal(&format!("could not keep the picture on the host: {e}"));
        }
        answer["path"] = json!(file.to_string_lossy());
    }
    answer
}

fn folder() -> PathBuf {
    paths::state_dir().join("mermaid")
}

/// Two hashes of the same text under different prefixes: 128 bits from the
/// hasher the standard library has, for a name that must not be shared by
/// two diagrams. The name only has to be stable for as long as a picture is
/// kept, so the hasher changing between Rust versions costs one redraw.
fn name(source: &str, dark: bool, scale: u8) -> String {
    let part = |salt: u8| {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (salt, env!("CARGO_PKG_VERSION"), dark, scale, source).hash(&mut hasher);
        hasher.finish()
    };
    format!("{:016x}{:016x}.png", part(1), part(2))
}

fn sweep(folder: &Path) {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let old = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|at| now.duration_since(at).ok())
            .is_some_and(|age| age > KEEP);
        if old && entry.path().extension().is_some_and(|e| e == "png") {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

/// A PNG and the size it says it is, or nothing for bytes that are not one.
fn picture(png: Vec<u8>, scale: u8) -> Option<Picture> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
    if png.len() < 24 || !png.starts_with(SIGNATURE) || &png[12..16] != b"IHDR" {
        return None;
    }
    let side = |at: usize| u32::from_be_bytes([png[at], png[at + 1], png[at + 2], png[at + 3]]);
    let (w, h) = (side(16), side(20));
    if w == 0 || h == 0 {
        return None;
    }
    Some(Picture { width: f64::from(w) / f64::from(scale), height: f64::from(h) / f64::from(scale), png })
}

fn fonts(control: &OperationControl) -> Result<merman::svg::export::NativeFontContext, String> {
    fn first(candidates: &[&'static str]) -> Option<PathBuf> {
        candidates.iter().map(PathBuf::from).find(|path| path.is_file())
    }
    let Some(file) = pingfang_asset().or_else(|| first(CJK_FONTS)).or_else(|| first(LATIN_FONTS)) else {
        return Err("this host has none of the fonts a diagram is drawn with".to_owned());
    };
    let limits = NativeFontLimits { max_bytes: MAX_FONT_BYTES, ..NativeFontLimits::default() };
    NativeFontOptions::default()
        .with_limits(limits)
        .with_font_file(file)
        .load(control)
        .map_err(|e| format!("the host's fonts could not be read: {e}"))
}

fn render(source: &str, dark: bool, scale: u8) -> Result<Picture, String> {
    // The defaults a diagram starts from; its own `%%{init}%%` still wins,
    // as it does in Mermaid.
    //
    // `wrappingWidth` — text wraps at Mermaid's 200 by measured width, which
    // broke "0.5ms 直接读取返回" onto two lines inside a box with room for
    // it. 320 keeps a `<br/>`-separated label on the lines its author wrote
    // (compared side by side 2026-11-15).
    //
    // `theme` is named only for dark. Left unnamed, Mermaid 12 draws its
    // current look (dark outlines on white, the one the owner chose from
    // side-by-side pictures); naming "default" selects the older lilac one.
    let mut site = json!({
        "fontFamily": FONT_FAMILY,
        "flowchart": { "wrappingWidth": 320 },
    });
    if dark {
        site["theme"] = json!("dark");
    }
    let control = OperationControl::new().with_deadline(DEADLINE);
    let environment = SvgEnvironment::deterministic()
        .with_resource_policy(RenderResourcePolicy::interactive())
        .with_native_font_context(fonts(&control)?)
        .map_err(|e| e.to_string())?;
    let renderer = Renderer::new()
        .with_presentation_engine(
            MermaidEngine::new().with_site_config(SourcePresentationConfig::from_value(site)),
        )
        .with_parse_options(ParseOptions::strict());
    let request = PngRequest {
        svg: SvgRequest { environment, ..SvgRequest::default() },
        // No matte: the picture is transparent, and sits on whatever the
        // client's page is.
        options: RasterOptions::default().with_scale(f32::from(scale)),
    };
    match renderer.render(RenderRequest::png(source, control, request)) {
        Ok(RenderOutput::Png(Some(png))) => picture(png.bytes().to_vec(), scale)
            .ok_or_else(|| "the renderer did not make a picture".to_owned()),
        Ok(_) => Err("no Mermaid diagram in this source".to_owned()),
        Err(e) => Err(e.to_string()),
    }
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLOW: &str = "flowchart TD\n    A[\"每 5 分钟\"] --> B{\"比缓存更新？<br/>第二行\"}\n    B -- \"是（刚聊过）\" --> C[\"直接返回\"]\n    B -- \"否\" --> D[\"调一次 /usage\"]\n";

    fn home() -> tempfile::TempDir {
        let home = tempfile::tempdir().unwrap();
        paths::TEST_HOME.with(|h| *h.borrow_mut() = Some(home.path().to_owned()));
        home
    }

    fn inline(source: &str, dark: bool, scale: u8) -> (Vec<u8>, f64, f64) {
        let a = answer(source, dark, scale, true);
        assert_eq!(a["mermaid"], true, "{a}");
        assert!(a.get("path").is_none());
        let png = crate::input::decode(a["png"].as_str().unwrap()).unwrap();
        (png, a["width"].as_f64().unwrap(), a["height"].as_f64().unwrap())
    }

    fn why(source: &str) -> String {
        let a = answer(source, false, 2, true);
        assert_eq!(a["mermaid"], false, "{a}");
        assert!(a.get("png").is_none() && a.get("path").is_none());
        a["why"].as_str().unwrap().to_owned()
    }

    #[test]
    fn a_flowchart_with_chinese_is_a_png_of_the_size_it_says() {
        let _home = home();
        let (png, width, height) = inline(FLOW, false, 2);
        let read = picture(png.clone(), 2).expect("a PNG");
        assert_eq!((read.width, read.height), (width, height));
        assert!(width > 100.0 && height > 100.0, "{width}x{height}");
        // Points, not pixels: three times the scale is the same picture in
        // the same number of points, with more pixels in it.
        let (larger, w3, h3) = inline(FLOW, false, 3);
        assert!(larger.len() > png.len());
        assert!((w3 - width).abs() < 1.0 && (h3 - height).abs() < 1.0, "{w3}x{h3} against {width}x{height}");
    }

    #[test]
    fn a_sequence_diagram_with_chinese_names_is_drawn() {
        let _home = home();
        inline("sequenceDiagram\n    participant 手机\n    participant CLI as attache-cli\n    手机->>CLI: 画这张图\n    CLI-->>手机: PNG\n", false, 2);
    }

    /// Kept under its own name by the clients, and under its own name here.
    #[test]
    fn dark_is_another_picture() {
        let _home = home();
        assert_ne!(inline(FLOW, false, 2).0, inline(FLOW, true, 2).0);
        assert_ne!(name(FLOW, false, 2), name(FLOW, true, 2));
        assert_ne!(name(FLOW, false, 2), name(FLOW, false, 3));
    }

    #[test]
    fn without_inline_the_picture_is_a_file_that_is_drawn_once() {
        let _home = home();
        let a = answer(FLOW, false, 2, false);
        assert_eq!(a["mermaid"], true, "{a}");
        assert!(a.get("png").is_none());
        let path = PathBuf::from(a["path"].as_str().unwrap());
        assert!(path.starts_with(folder()), "{path:?}");
        let first = std::fs::read(&path).unwrap();
        assert!(picture(first.clone(), 2).is_some());
        // Asked again, the file answers: put other bytes of a PNG there and
        // they are what comes back, which a second render would not be.
        let (other, _, _) = inline("flowchart LR\n  X --> Y\n", false, 2);
        std::fs::write(&path, &other).unwrap();
        let again = answer(FLOW, false, 2, false);
        assert_eq!(again["path"], a["path"]);
        assert_eq!(std::fs::read(&path).unwrap(), other);
        // And a file that is not a picture is drawn over, not handed out.
        std::fs::write(&path, b"cut short").unwrap();
        answer(FLOW, false, 2, false);
        assert_eq!(std::fs::read(&path).unwrap(), first);
    }

    #[test]
    fn what_cannot_be_drawn_says_why_and_draws_nothing() {
        let _home = home();
        assert!(!why("flowchart TD\n  A[\"never closed --> B\n").is_empty());
        assert!(!why("just some words, not a diagram\n").is_empty());
        assert!(!why("").is_empty());
        assert_eq!(why(&format!("flowchart TD\n  A[\"{}\"]\n", "x".repeat(MAX_SOURCE))), "the diagram is too long");
        assert!(!folder().exists(), "a refusal leaves nothing on the host");
    }

    #[test]
    fn base64_is_what_decode_reads() {
        for bytes in [&b""[..], b"a", b"ab", b"abc", b"\x00\xff\x10\x80\x7f"] {
            assert_eq!(crate::input::decode(&base64(bytes)).unwrap(), bytes);
        }
    }
}
