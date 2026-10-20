//! Thumbnails and ThumbHashes of the images sent in chats, for the station in TypeScript (src/sessions/thumbs.ts): the
//! Rust station's mesh/app/src/thumbs.rs as it is (the same `image` and `thumbhash` crates, at the versions mesh/ is
//! built with, so both stations make the same bytes), its decoding and encoding off Node's thread. Which files, when,
//! and what is kept with a message: the TypeScript's.

use std::io::Cursor;
use std::path::{Path, PathBuf};

use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader};
use napi_derive::napi;
use sha2::{Digest, Sha256};

/// The largest a chat shows an image (its box is at most 360×300), at twice that for sharp screens.
const MAX_W: u32 = 720;
const MAX_H: u32 = 600;
/// An image already this small is shown itself.
const SMALL: u64 = 24 * 1024;

/// Whether a file is an image a thumbnail is made for (a GIF would lose its motion).
fn wanted(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".webp"].iter().any(|e| lower.ends_with(e))
}

/// thumbs.rs `thumbnail`.
fn thumbnail_of(image: &Path, dir: &Path) -> Option<(PathBuf, &'static str)> {
    let name = image.file_name()?.to_str()?;
    if !wanted(name) {
        return None;
    }
    let len = std::fs::metadata(image).ok()?.len();
    if len <= SMALL {
        return None;
    }
    let id = id_of(image);
    kept(dir, &id).or_else(|| make(decode(image)?, len, dir, &id))
}

fn id_of(image: &Path) -> String {
    hex::encode(&Sha256::digest(image.to_string_lossy().as_bytes())[..16])
}

fn kept(dir: &Path, id: &str) -> Option<(PathBuf, &'static str)> {
    [("jpg", "image/jpeg"), ("png", "image/png")].into_iter().map(|(ext, kind)| (dir.join(format!("{id}.{ext}")), kind)).find(|(path, _)| path.is_file())
}

/// The image as it is seen: turned as its camera says (a photo's EXIF), which a copy without that note must do itself.
fn decode(image: &Path) -> Option<DynamicImage> {
    let mut decoder = ImageReader::open(image).ok()?.with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut decoded = DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        decoded.apply_orientation(orientation);
    }
    Some(decoded)
}

fn make(decoded: DynamicImage, len: u64, dir: &Path, id: &str) -> Option<(PathBuf, &'static str)> {
    // Resampled with care: most are screenshots of text, which a quick filter leaves jagged.
    let small = if decoded.width() > MAX_W || decoded.height() > MAX_H { decoded.resize(MAX_W, MAX_H, FilterType::CatmullRom) } else { decoded };
    // Clear parts stay clear (PNG); anything else is a photo or a screenshot, smallest as JPEG.
    let clear = small.color().has_alpha() && small.to_rgba8().pixels().any(|p| p.0[3] < 255);
    let (ext, kind, bytes) = if clear { ("png", "image/png", png(&small)?) } else { ("jpg", "image/jpeg", jpeg(&small)?) };
    // No smaller than the image itself: it is shown as it is.
    if bytes.len() as u64 >= len {
        return None;
    }
    std::fs::create_dir_all(dir).ok()?;
    let path = dir.join(format!("{id}.{ext}"));
    // Written whole before it is there to be read.
    let partial = dir.join(format!("{id}.{ext}.part"));
    std::fs::write(&partial, bytes).ok()?;
    std::fs::rename(&partial, &path).ok()?;
    Some((path, kind))
}

fn png(image: &DynamicImage) -> Option<Vec<u8>> {
    let mut out = Cursor::new(Vec::new());
    image.write_to(&mut out, ImageFormat::Png).ok()?;
    Some(out.into_inner())
}

/// Quality high enough that small text keeps its edges.
fn jpeg(image: &DynamicImage) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    image.to_rgb8().write_with_encoder(JpegEncoder::new_with_quality(&mut out, 88)).ok()?;
    Some(out)
}

/// The image's ThumbHash (base64), taken from it at most 100px across, as the format wants.
fn hash(image: &DynamicImage) -> String {
    let small = image.thumbnail(100, 100).to_rgba8();
    let bytes = thumbhash::rgba_to_thumb_hash(small.width() as usize, small.height() as usize, small.as_raw());
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[napi(object)]
pub struct Thumbnail {
    pub path: String,
    /// Its content type: image/jpeg, or image/png for one with clear parts.
    #[napi(js_name = "type")]
    pub kind: String,
}

/// thumbs.rs `thumbnail`: the image's thumbnail in `dir` and its type, made if it is not there yet; null when the image
/// is shown itself (not a png/jpg/jpeg/webp by its name, 24 KiB or less, not readable as an image, or no smaller made).
#[napi]
pub async fn thumbnail(image: String, dir: String) -> Option<Thumbnail> {
    let found = tokio::task::spawn_blocking(move || thumbnail_of(Path::new(&image), Path::new(&dir))).await.ok().flatten()?;
    Some(Thumbnail { path: found.0.to_string_lossy().into_owned(), kind: found.1.to_string() })
}

#[napi(object)]
pub struct Hashed {
    /// The ThumbHash, base64.
    pub hash: String,
    /// The image as it is seen (turned as its EXIF says).
    pub width: u32,
    pub height: u32,
}

/// thumbs.rs `keep`, for one image: its ThumbHash, decoded once, and with `dir` its thumbnail made from the same decoding
/// after (off the caller's thread, not waited for) when the image is over 24 KiB and has none yet. Null when it is not
/// readable as an image. Which images (by the attachment's name): the caller's.
#[napi]
pub async fn thumbhash(image: String, dir: Option<String>) -> Option<Hashed> {
    tokio::task::spawn_blocking(move || {
        let path = PathBuf::from(&image);
        let decoded = decode(&path)?;
        let hashed = Hashed { hash: hash(&decoded), width: decoded.width(), height: decoded.height() };
        let len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if let Some(dir) = dir.filter(|_| len > SMALL) {
            let (dir, id) = (PathBuf::from(dir), id_of(&path));
            std::thread::spawn(move || {
                if kept(&dir, &id).is_none() {
                    let _ = make(decoded, len, &dir, &id);
                }
            });
        }
        Some(hashed)
    })
    .await
    .ok()
    .flatten()
}
