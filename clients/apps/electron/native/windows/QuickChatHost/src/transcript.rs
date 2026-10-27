//! The words being said, in a box above the taskbar, as the overlay page's Transcript (the macOS QuickChatHost's
//! TranscriptLayer): characters appear one at a time as they are recognized, one a frame, more a frame when the
//! recognizer delivers a burst, so the text never trails the voice. The text is as large as fits the box, centered in
//! it; once it no longer fits it shrinks, and at the smallest size it grows above the box up to `MAXIMUM_HEIGHT`.
//! Taller still, it scrolls to its last line, under a fade at each edge with more text beyond, and the wheel over it
//! shows the earlier lines. Sending moves it: each line, lowest first, rises with the wave and fades, blurring as it
//! goes. While Quick Chat waits for words, a band of light sweeps across the hint.
//!
//! Sizes are in DIPs, as the page had them; `Area` places the box on the overlay in px.

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::{ID2D1Brush, D2D1_ANTIALIAS_MODE_ALIASED, D2D1_DRAW_TEXT_OPTIONS_NONE};
use windows::Win32::Graphics::DirectWrite::{IDWriteTextLayout, DWRITE_TEXT_METRICS, DWRITE_TEXT_RANGE};
use windows::core::Interface;
use windows_numerics::{Matrix3x2, Vector2};

use crate::motion::{settle, spring};
use crate::text::{color, layout_height, layout_lines, rect, Baked, Ink};
use crate::transcript_fit::{fit_transcript, Fit, TranscriptScroll};

pub const MAXIMUM_SIZE: f32 = 24.0;
pub const MINIMUM_SIZE: f32 = 15.0;
/// Line height as a multiple of the size.
const LEADING: f32 = 1.3;
pub fn line_height(size: f32) -> f32 {
    (size * LEADING).round()
}
/// The box holds three lines at the largest size.
pub fn box_height() -> f32 {
    line_height(MAXIMUM_SIZE) * 3.0
}
/// Seven lines at the smallest size.
pub fn maximum_height() -> f32 {
    line_height(MINIMUM_SIZE) * 7.0
}
/// A burst is shown over at most this many frames.
const CATCH_UP_FRAMES: usize = 6;
/// The fade at an edge with more text beyond it, which deepens over `FADE_RAMP` of hidden text.
const FADE_HEIGHT: f32 = 28.0;
const FADE_RAMP: f32 = 6.0;
/// The band of light: three times the largest size wide, across in 1.4 s, then 0.6 s at rest.
const BAND_WIDTH: f32 = MAXIMUM_SIZE * 3.0;
const SHIMMER_SECONDS: f64 = 2.0;
const CANCEL_SECONDS: f64 = 0.15;
/// The halo, CSS's `text-shadow: 0 0 16px rgb(0 0 0 / 0.6)`.
const HALO_SIGMA: f32 = 8.0;
const HALO_ALPHA: f32 = 0.6;
const WORD_ALPHA: f32 = 0.96;
const HINT_ALPHA: f32 = 0.5;
/// NameDrop's tempo, which the send's motion keeps.
pub const TEMPO: f64 = 2.2;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Style {
    /// Waiting for words: dim, with the band of light.
    Waiting,
    /// A hint: dim.
    Hint,
    /// A message, as bright as words.
    Message,
}

/// Where the words go on the overlay, in px: the box's left and bottom, its width, and the display's scale.
#[derive(Clone, Copy, Default, Debug)]
pub struct Area {
    pub left: f32,
    pub bottom: f32,
    pub width: f32,
    pub scale: f32,
}

pub fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// How high `text` is set at `size`, `width` px wide, in DIPs.
pub fn measure(ink: &Ink, text: &[u16], size: f32, area: Area) -> f32 {
    if text.is_empty() {
        return 0.0;
    }
    let format = ink.format(size * area.scale, line_height(size) * area.scale, true);
    match format.and_then(|format| ink.layout(text, &format, area.width)) {
        Ok(layout) => layout_height(&layout) / area.scale,
        Err(_) => f32::MAX,
    }
}

/// The size `text` is set at, as the words and the editor set it.
pub fn fit(ink: &Ink, text: &[u16], area: Area) -> Fit {
    fit_transcript(box_height(), MAXIMUM_SIZE, MINIMUM_SIZE, |size| measure(ink, text, size, area))
}

/// The text's leaving: the send's rise, or a close's fade.
enum Leaving {
    Send { since: f64, distance: f32, layout: IDWriteTextLayout, top: f32, lines: Vec<Line> },
    Cancel { since: f64 },
}

struct Line {
    start: u32,
    length: u32,
    index: usize,
    opacity: f32,
}

pub struct Transcript {
    area: Area,
    text: Vec<u16>,
    /// Where each character ends in `text`.
    ends: Vec<usize>,
    /// How many characters are shown; the rest wait for the next frames.
    shown: usize,
    font_size: f32,
    scroll: TranscriptScroll,
    layout: Option<IDWriteTextLayout>,
    /// The text's height, DIPs.
    height: f32,
    placeholder: Vec<u16>,
    style: Style,
    placeholder_shown: bool,
    placeholder_layout: Option<IDWriteTextLayout>,
    /// When the band of light started sweeping.
    shimmer_since: f64,
    leaving: Option<Leaving>,
    /// Hidden while the editor shows the words.
    pub hidden: bool,
    /// The words and the hint with their halo as last drawn, and what they were drawn from: drawn again only when that
    /// changes.
    words_baked: Option<(String, Option<Baked>)>,
    hint_baked: Option<(String, Option<Baked>)>,
}

impl Transcript {
    pub fn new() -> Self {
        Self {
            area: Area::default(),
            text: Vec::new(),
            ends: Vec::new(),
            shown: 0,
            font_size: MAXIMUM_SIZE,
            scroll: TranscriptScroll::default(),
            layout: None,
            height: 0.0,
            placeholder: Vec::new(),
            style: Style::Hint,
            placeholder_shown: true,
            placeholder_layout: None,
            shimmer_since: 0.0,
            leaving: None,
            hidden: false,
            words_baked: None,
            hint_baked: None,
        }
    }

    pub fn set_area(&mut self, area: Area) {
        self.area = area;
        self.words_baked = None;
        self.hint_baked = None;
        self.layout = None;
        self.placeholder_layout = None;
    }

    pub fn has_words(&self) -> bool {
        !self.ends.is_empty()
    }

    /// True while the text is taller than its box.
    pub fn scrolls(&self) -> bool {
        self.scroll.overflow > 0.0
    }

    /// How far the text is scrolled back from its last line, DIPs.
    pub fn scrolled_back(&self) -> f32 {
        self.scroll.offset
    }

    /// Clears the text and shows `text` as the placeholder until words arrive.
    pub fn reset(&mut self, ink: &Ink, text: &str, style: Style, now: f64) {
        self.leaving = None;
        self.text.clear();
        self.ends.clear();
        self.shown = 0;
        self.font_size = MAXIMUM_SIZE;
        self.scroll = TranscriptScroll::default();
        self.layout = None;
        self.height = 0.0;
        self.placeholder_shown = true;
        self.set_placeholder(ink, text, style, now);
    }

    pub fn set_placeholder(&mut self, _ink: &Ink, text: &str, style: Style, now: f64) {
        let text = utf16(text);
        if text != self.placeholder || style != self.style {
            if style == Style::Waiting && (self.style != Style::Waiting || text != self.placeholder) {
                self.shimmer_since = now;
            }
            self.placeholder = text;
            self.style = style;
            self.placeholder_layout = None;
        }
    }

    /// Shows `text`, keeping the characters it shares with what is shown. Characters that replace shown ones (a
    /// corrected phrase) appear at once; the ones after appear one by one over the next frames, or at once when
    /// `revealed` (words that were already on screen, in the editor).
    pub fn set_text(&mut self, ink: &Ink, text: &str, revealed: bool) {
        let next = utf16(text);
        if next == self.text && !revealed {
            return;
        }
        let mut ends = Vec::new();
        let mut at = 0;
        for c in text.chars() {
            at += c.len_utf16();
            ends.push(at);
        }
        let fit = fit(ink, &next, self.area);
        self.font_size = fit.font_size;
        self.height = measure(ink, &next, fit.font_size, self.area);
        self.scroll.set_overflow(self.height - maximum_height());
        self.shown = if revealed { ends.len() } else { self.shown.min(ends.len()) };
        self.text = next;
        self.ends = ends;
        self.layout = None;
        if !self.ends.is_empty() {
            self.placeholder_shown = false;
        }
        self.tick();
    }

    /// A frame: the next characters waiting appear.
    pub fn tick(&mut self) {
        let waiting = self.ends.len().saturating_sub(self.shown);
        if waiting > 0 {
            self.shown += waiting.div_ceil(CATCH_UP_FRAMES).max(1);
        }
    }

    /// Scrolls the text back from its last line by `offset`, as the editor had it.
    pub fn scroll_back(&mut self, offset: f32) {
        if self.scrolls() {
            self.scroll.scroll(offset - self.scroll.offset);
        }
    }

    /// A wheel over the words, `notches` toward the first line: a line a notch, as on macOS.
    pub fn wheel(&mut self, notches: f32) {
        if self.scrolls() {
            self.scroll.scroll(notches * line_height(self.font_size));
        }
    }

    /// The text's top and bottom on the overlay, px.
    fn content_span(&self) -> (f32, f32) {
        let scale = self.area.scale;
        let bottom = if self.scrolls() {
            -self.scroll.offset
        } else if self.height > box_height() {
            0.0
        } else {
            (box_height() - self.height) / 2.0
        };
        let bottom = self.area.bottom - bottom * scale;
        (bottom - self.height * scale, bottom)
    }

    /// The box the words show in, px: as high as they can grow.
    fn box_top(&self) -> f32 {
        self.area.bottom - maximum_height() * self.area.scale
    }

    /// How far above the box's bottom the shown words reach, DIPs; None with none.
    pub fn words_top(&self) -> Option<f32> {
        if self.ends.is_empty() || self.hidden {
            return None;
        }
        let (top, _) = self.content_span();
        Some((self.area.bottom - top.max(self.box_top())) / self.area.scale)
    }

    /// Whether (`x`, `y`) on the overlay is over the words drawn (not the hint), inside their box.
    pub fn over_words(&self, x: f32, y: f32) -> bool {
        if self.hidden || self.ends.is_empty() || self.leaving.is_some() {
            return false;
        }
        let (top, bottom) = self.content_span();
        x >= self.area.left
            && x <= self.area.left + self.area.width
            && y >= top.max(self.box_top())
            && y <= bottom.min(self.area.bottom)
    }

    /// Where (`x`, `y`) on the overlay falls in the words, as an offset into their text (UTF-16): before or after the
    /// character nearest it on its line; None off every line.
    pub fn index_at(&mut self, ink: &Ink, x: f32, y: f32) -> Option<usize> {
        let layout = self.layout(ink).ok()?;
        let (top, bottom) = self.content_span();
        if y < top || y >= bottom {
            return None;
        }
        let (position, _) = crate::text::hit(&layout, x - self.area.left, y - top);
        Some(position as usize)
    }

    fn layout(&mut self, ink: &Ink) -> Result<IDWriteTextLayout> {
        if let Some(layout) = &self.layout {
            return Ok(layout.clone());
        }
        let scale = self.area.scale;
        let format = ink.format(self.font_size * scale, line_height(self.font_size) * scale, true)?;
        let layout = ink.layout(&self.text, &format, self.area.width)?;
        self.layout = Some(layout.clone());
        Ok(layout)
    }

    /// The text leaves with the wave: each line, lowest first, rises `distance` px and fades, blurring as it goes.
    pub fn send(&mut self, ink: &Ink, distance: f32, now: f64) {
        self.shown = self.ends.len();
        self.placeholder_shown = false;
        let Ok(layout) = self.layout(ink) else { return };
        let _ = unsafe { layout.SetDrawingEffect(None::<&windows::core::IUnknown>, range(0, self.text.len())) };
        let (top, _) = self.content_span();
        let line = line_height(self.font_size) * self.area.scale;
        let masked = self.scrolls();
        let box_bottom = self.area.bottom;
        let box_height = maximum_height() * self.area.scale;
        let fade = FADE_HEIGHT * self.area.scale;
        let lines = layout_lines(&layout)
            .into_iter()
            .enumerate()
            .map(|(index, (start, length))| {
                let said = String::from_utf16_lossy(&self.text[start as usize..(start + length) as usize]);
                let mut opacity = if said.trim().is_empty() { 0.0 } else { 1.0 };
                if masked && opacity > 0.0 {
                    // Up from the box's bottom, as the fades are measured.
                    let bottom = box_bottom - (top + (index as f32 + 1.0) * line);
                    let covered = |inset: f32| (1.0 - inset / fade).clamp(0.0, 1.0);
                    let below = 1.0 - fade_depth(self.scroll.hidden_below()) * covered(bottom);
                    let above = 1.0 - fade_depth(self.scroll.hidden_above()) * covered(box_height - bottom - line);
                    opacity = below.min(above);
                }
                Line { start, length, index, opacity }
            })
            .collect();
        self.leaving = Some(Leaving::Send { since: now, distance, layout, top, lines });
        self.text.clear();
        self.ends.clear();
        self.shown = 0;
        self.layout = None;
    }

    /// Closing without sending: the text goes with the hint.
    pub fn cancel(&mut self, now: f64) {
        if self.leaving.is_none() {
            self.leaving = Some(Leaving::Cancel { since: now });
        }
    }

    pub fn draw(&mut self, ink: &Ink, now: f64) -> Result<()> {
        if let Some(Leaving::Send { .. }) = &self.leaving {
            return self.draw_send(ink, now);
        }
        let fading = match &self.leaving {
            Some(Leaving::Cancel { since }) => 1.0 - settle(now - since, CANCEL_SECONDS),
            _ => 1.0,
        };
        if self.hidden || fading <= 0.0 {
            return Ok(());
        }
        if self.placeholder_shown && !self.placeholder.is_empty() {
            self.draw_placeholder(ink, now, fading)?;
        }
        if !self.ends.is_empty() {
            self.draw_words(ink, fading)?;
        }
        Ok(())
    }

    fn draw_words(&mut self, ink: &Ink, opacity: f32) -> Result<()> {
        let layout = self.layout(ink)?;
        // The characters not yet shown are drawn clear: the shown ones stay where the whole text puts them.
        let shown = self.ends.get(self.shown.wrapping_sub(1)).copied().unwrap_or(0);
        unsafe {
            layout.SetDrawingEffect(None::<&windows::core::IUnknown>, range(0, shown))?;
            if shown < self.text.len() {
                layout.SetDrawingEffect(&ink.clear, range(shown, self.text.len() - shown))?;
            }
        }
        let (top, _) = self.content_span();
        let left = self.area.left;
        let key = format!("{}|{}|{}|{}|{}", self.shown, top, left, self.font_size, String::from_utf16_lossy(&self.text));
        if self.words_baked.as_ref().is_none_or(|(baked, _)| *baked != key) {
            let words = ink.group(|context| unsafe {
                ink.white.SetOpacity(WORD_ALPHA);
                context.DrawTextLayout(Vector2::new(left, top), &layout, &ink.white, D2D1_DRAW_TEXT_OPTIONS_NONE);
                ink.white.SetOpacity(1.0);
                Ok(())
            })?;
            let words = ink.with_halo(&words, HALO_SIGMA * self.area.scale, HALO_ALPHA)?;
            self.words_baked = Some((key, ink.bake(&words)?));
        }
        let Some((_, Some(words))) = &self.words_baked else { return Ok(()) };
        if self.scrolls() {
            // In the box, fading out at an edge with more text beyond it.
            let (box_top, bottom) = (self.box_top(), self.area.bottom);
            let fade = FADE_HEIGHT * self.area.scale;
            let below = 1.0 - fade_depth(self.scroll.hidden_below());
            let above = 1.0 - fade_depth(self.scroll.hidden_above());
            let span = bottom - box_top;
            let mask = ink.gradient(
                &[
                    (0.0, color(0.0, 0.0, 0.0, below)),
                    (fade / span, color(0.0, 0.0, 0.0, 1.0)),
                    (1.0 - fade / span, color(0.0, 0.0, 0.0, 1.0)),
                    (1.0, color(0.0, 0.0, 0.0, above)),
                ],
                Vector2::new(0.0, bottom),
                Vector2::new(0.0, box_top),
            )?;
            unsafe {
                ink.context.PushAxisAlignedClip(&rect(-1e6, box_top, 1e6, bottom), D2D1_ANTIALIAS_MODE_ALIASED);
            }
            ink.draw_baked(words, opacity, Some(&mask.cast::<ID2D1Brush>()?))?;
            unsafe { ink.context.PopAxisAlignedClip() };
        } else {
            ink.draw_baked(words, opacity, None)?;
        }
        Ok(())
    }

    fn draw_placeholder(&mut self, ink: &Ink, now: f64, opacity: f32) -> Result<()> {
        let scale = self.area.scale;
        if self.placeholder_layout.is_none() {
            let format = ink.format(MAXIMUM_SIZE * scale, line_height(MAXIMUM_SIZE) * scale, true)?;
            self.placeholder_layout = Some(ink.layout(&self.placeholder, &format, self.area.width)?);
        }
        let layout = self.placeholder_layout.clone().unwrap();
        let height = layout_height(&layout);
        let top = self.area.bottom - (box_height() * scale - height) / 2.0 - height;
        let left = self.area.left;
        let alpha = if self.style == Style::Message { WORD_ALPHA } else { HINT_ALPHA };
        let key = format!("{:?}|{}|{}|{}", self.style, top, left, String::from_utf16_lossy(&self.placeholder));
        if self.hint_baked.as_ref().is_none_or(|(baked, _)| *baked != key) {
            let hint = ink.group(|context| unsafe {
                ink.white.SetOpacity(alpha);
                context.DrawTextLayout(Vector2::new(left, top), &layout, &ink.white, D2D1_DRAW_TEXT_OPTIONS_NONE);
                ink.white.SetOpacity(1.0);
                Ok(())
            })?;
            let hint = ink.with_halo(&hint, HALO_SIGMA * scale, HALO_ALPHA)?;
            self.hint_baked = Some((key, ink.bake(&hint)?));
        }
        if let Some((_, Some(hint))) = &self.hint_baked {
            ink.draw_baked(hint, opacity, None)?;
        }
        if self.style == Style::Waiting && self.ends.is_empty() && animations_on() {
            // A lighter copy of the hint, without its halo, that the band of light shows through: from before the
            // ink to past it in 1.4 s, then at rest 0.6 s.
            let mut metrics = DWRITE_TEXT_METRICS::default();
            unsafe { layout.GetMetrics(&mut metrics)? };
            let band = BAND_WIDTH * scale;
            let (from, to) = (left + metrics.left - band, left + metrics.left + metrics.width);
            let phase = ((now - self.shimmer_since).rem_euclid(SHIMMER_SECONDS) / SHIMMER_SECONDS / 0.7).min(1.0) as f32;
            let at = from + (to - from) * phase;
            let brush = ink.gradient(
                &[
                    (0.0, color(1.0, 1.0, 1.0, 0.0)),
                    (0.5, color(1.0, 1.0, 1.0, 0.8 * opacity)),
                    (1.0, color(1.0, 1.0, 1.0, 0.0)),
                ],
                Vector2::new(at, 0.0),
                Vector2::new(at + band, 0.0),
            )?;
            unsafe {
                ink.context.DrawTextLayout(Vector2::new(left, top), &layout, &brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
            }
        }
        Ok(())
    }

    fn draw_send(&mut self, ink: &Ink, now: f64) -> Result<()> {
        let Some(Leaving::Send { since, distance, layout, top, lines }) = &self.leaving else { return Ok(()) };
        let elapsed = now - since;
        let scale = self.area.scale;
        let line = line_height(self.font_size) * scale;
        let left = self.area.left;
        let last = lines.iter().filter(|l| l.opacity > 0.0).map(|l| l.index).max().unwrap_or(0);
        let mut parts = Vec::new();
        for l in lines.iter().filter(|l| l.opacity > 0.0) {
            // Lower lines leave first, by less than it takes them to reach the line above.
            let begin = (0.03 + (last - l.index) as f64 * 0.012) / TEMPO;
            let rise = spring(elapsed - begin, 1.8 * TEMPO) * distance;
            let opacity = l.opacity * (1.0 - spring(elapsed - begin - 0.06 / TEMPO, 2.0 * TEMPO));
            if opacity <= 0.001 {
                continue;
            }
            let y = top + l.index as f32 * line;
            let (start, length) = (l.start, l.length);
            let text = ink.group(|context| unsafe {
                // This line of the text, where it was, risen.
                context.SetTransform(&Matrix3x2::translation(0.0, -rise));
                context.PushAxisAlignedClip(&rect(-1e6, y, 1e6, y + line), D2D1_ANTIALIAS_MODE_ALIASED);
                layout.SetDrawingEffect(&ink.clear, range(0, start as usize))?;
                layout.SetDrawingEffect(None::<&windows::core::IUnknown>, range(start as usize, length as usize))?;
                ink.white.SetOpacity(WORD_ALPHA);
                context.DrawTextLayout(Vector2::new(left, *top), layout, &ink.white, D2D1_DRAW_TEXT_OPTIONS_NONE);
                ink.white.SetOpacity(1.0);
                context.PopAxisAlignedClip();
                Ok(())
            })?;
            parts.push((ink.with_halo(&text, HALO_SIGMA * scale, HALO_ALPHA)?, opacity));
        }
        if parts.is_empty() {
            return Ok(());
        }
        let all = ink.group(|_| {
            for (part, opacity) in &parts {
                ink.draw_image(part, *opacity, None)?;
            }
            Ok(())
        })?;
        let blur = 10.0 * scale * spring(elapsed - 0.06 / TEMPO, 1.8 * TEMPO);
        // CSS's blur(r) is a Gaussian of deviation r.
        ink.draw_image(&ink.blurred(&all, blur)?, 1.0, None)
    }
}

fn range(start: usize, length: usize) -> DWRITE_TEXT_RANGE {
    DWRITE_TEXT_RANGE { startPosition: start as u32, length: length as u32 }
}

/// Windows' "Animation effects" (Settings > Accessibility > Visual effects); off, the band of light does not sweep,
/// as prefers-reduced-motion stopped it in the page.
fn animations_on() -> bool {
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETCLIENTAREAANIMATION, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };
    let mut on = windows::core::BOOL(1);
    unsafe {
        let _ = SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some(&mut on as *mut _ as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        );
    }
    on.as_bool()
}

fn fade_depth(hidden: f32) -> f32 {
    (hidden / FADE_RAMP).min(1.0)
}
