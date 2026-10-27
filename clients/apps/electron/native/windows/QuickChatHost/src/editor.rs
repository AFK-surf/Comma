//! The words opened for editing, as the overlay page's textarea: set as the drawn words are (the size that fits the
//! box, centered in it, growing above it up to seven lines, scrolling past them), with a white caret and a light
//! selection. It takes typing, the input method's composition (drawn underlined where it goes), the arrows, Home and
//! End (with Shift to select, with Ctrl a word at a time), Backspace and Delete (with Ctrl a word), Ctrl+A, C, X and
//! V, Ctrl+Z and Ctrl+Y (or Ctrl+Shift+Z), clicks, double-clicks (a word), drags, and the wheel.
//!
//! Offsets are UTF-16, as DirectWrite counts them.

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::{D2D1_ANTIALIAS_MODE_ALIASED, D2D1_DRAW_TEXT_OPTIONS_NONE};
use windows::Win32::Graphics::DirectWrite::{IDWriteTextLayout, DWRITE_TEXT_RANGE};
use windows_numerics::Vector2;

use crate::text::{caret_at, color, hit, layout_height, range_rects, rect, Baked, Ink};
use crate::transcript::{box_height, fit, line_height, maximum_height, Area};

const HALO_SIGMA: f32 = 8.0;
const HALO_ALPHA: f32 = 0.6;
const WORD_ALPHA: f32 = 0.96;
/// The caret is on for half a second, then off for half a second, from the last change.
const BLINK_SECONDS: f64 = 0.5;

pub struct Editor {
    area: Area,
    pub text: Vec<u16>,
    caret: usize,
    anchor: usize,
    /// The input method's composition and its caret, at `caret`.
    composition: Option<(Vec<u16>, usize)>,
    /// How far the text is scrolled down from its first line, px.
    scroll_top: f32,
    font_size: f32,
    layout: Option<IDWriteTextLayout>,
    /// The text's height and the editor's, px, and its bottom above the box's, px.
    content_height: f32,
    shown_height: f32,
    bottom: f32,
    /// When the caret last moved or the text changed: the blink starts over.
    since: f64,
    /// A drag selecting from where it was pressed.
    pub dragging: bool,
    /// The x Up and Down keep, px.
    goal_x: Option<f32>,
    /// The words with their halo as last drawn, and what they were drawn from.
    baked: Option<(String, Option<Baked>)>,
    /// What undo and redo go back and forth through: the text, caret and anchor before each change.
    undo: Vec<(Vec<u16>, usize, usize)>,
    redo: Vec<(Vec<u16>, usize, usize)>,
    /// Characters typed one after another undo together.
    typing: bool,
}

/// What a character is, for moving and erasing a word at a time: a run of letters and digits, or of CJK, is a word;
/// space after a word is passed over with it; any other mark is a word of its own.
#[derive(PartialEq, Eq, Clone, Copy)]
enum Kind {
    Space,
    Latin,
    Cjk,
    Mark,
}

fn kind(unit: u16) -> Kind {
    let c = char::from_u32(unit as u32).unwrap_or('a');
    if c.is_whitespace() {
        Kind::Space
    } else if matches!(unit, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
        || (0xD800..0xE000).contains(&unit)
    {
        Kind::Cjk
    } else if c.is_alphanumeric() || c == '_' || c == '\'' {
        Kind::Latin
    } else {
        Kind::Mark
    }
}

impl Editor {
    pub fn new() -> Self {
        Self {
            area: Area::default(),
            text: Vec::new(),
            caret: 0,
            anchor: 0,
            composition: None,
            scroll_top: 0.0,
            font_size: crate::transcript::MAXIMUM_SIZE,
            layout: None,
            content_height: 0.0,
            shown_height: 0.0,
            bottom: 0.0,
            since: 0.0,
            dragging: false,
            goal_x: None,
            baked: None,
            undo: Vec::new(),
            redo: Vec::new(),
            typing: false,
        }
    }

    pub fn string(&self) -> String {
        String::from_utf16_lossy(&self.text)
    }

    /// Opens `text` where the words were drawn, scrolled back as far (DIPs), with the caret at `caret` or its end.
    pub fn open(&mut self, ink: &Ink, area: Area, text: &str, scrolled_back: f32, caret: Option<usize>, now: f64) {
        self.area = area;
        self.text = text.encode_utf16().collect();
        self.caret = caret.unwrap_or(self.text.len()).min(self.text.len());
        self.anchor = self.caret;
        self.composition = None;
        self.dragging = false;
        self.goal_x = None;
        self.undo.clear();
        self.redo.clear();
        self.typing = false;
        self.refit(ink, now);
        self.scroll_top = (self.content_height - self.shown_height - scrolled_back * area.scale).max(0.0);
    }

    /// How far the text is scrolled back from its last line, DIPs.
    pub fn scrolled_back(&self) -> f32 {
        (self.content_height - self.shown_height - self.scroll_top).max(0.0) / self.area.scale
    }

    /// How far above the box's bottom the editor reaches, DIPs.
    pub fn top(&self) -> f32 {
        (self.bottom + self.shown_height) / self.area.scale
    }

    /// The editor on the overlay, px.
    fn frame(&self) -> (f32, f32) {
        let bottom = self.area.bottom - self.bottom;
        (bottom - self.shown_height, bottom)
    }

    /// The whole text area (as high as the words can grow), which takes the pointer while editing.
    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.area.left
            && x <= self.area.left + self.area.width
            && y >= self.area.bottom - maximum_height() * self.area.scale
            && y <= self.area.bottom
    }

    /// The text shown: the composition at the caret.
    fn shown(&self) -> Vec<u16> {
        match &self.composition {
            Some((composition, _)) => {
                let mut text = self.text[..self.caret].to_vec();
                text.extend_from_slice(composition);
                text.extend_from_slice(&self.text[self.caret..]);
                text
            }
            None => self.text.clone(),
        }
    }

    /// Sets the text as the drawn words would be: the size that fits the box, centered in it, growing above it.
    fn refit(&mut self, ink: &Ink, now: f64) {
        self.since = now;
        let text = self.shown();
        let fit = fit(ink, &text, self.area);
        self.font_size = fit.font_size;
        let scale = self.area.scale;
        let line = line_height(fit.font_size) * scale;
        self.layout = ink
            .format(fit.font_size * scale, line, true)
            .and_then(|format| ink.layout(&text, &format, self.area.width))
            .ok();
        // An empty text, or one ending in a line break, still has the line the caret is on.
        let height = self.layout.as_ref().map(layout_height).unwrap_or(line);
        self.content_height = if text.is_empty() { line } else { height.max(line) };
        self.shown_height = self.content_height.min(maximum_height() * scale);
        self.bottom = if fit.overflow > 0.0 { 0.0 } else { (box_height() * scale - self.content_height) / 2.0 };
        self.scroll_top = self.scroll_top.clamp(0.0, (self.content_height - self.shown_height).max(0.0));
        self.reveal_caret();
    }

    /// Scrolls the caret's line into view.
    fn reveal_caret(&mut self) {
        let Some(layout) = &self.layout else { return };
        let (_, top, height) = caret_at(layout, self.shown_caret() as u32);
        if top < self.scroll_top {
            self.scroll_top = top;
        } else if top + height > self.scroll_top + self.shown_height {
            self.scroll_top = top + height - self.shown_height;
        }
    }

    fn shown_caret(&self) -> usize {
        self.caret + self.composition.as_ref().map(|(_, at)| *at).unwrap_or(0)
    }

    fn selection(&self) -> (usize, usize) {
        (self.caret.min(self.anchor), self.caret.max(self.anchor))
    }

    pub fn selected(&self) -> String {
        let (from, to) = self.selection();
        String::from_utf16_lossy(&self.text[from..to])
    }

    /// Keeps the text as it is for undo, before a change; characters typed one after another are one change.
    fn remember(&mut self, typing: bool) {
        if !(typing && self.typing) {
            self.undo.push((self.text.clone(), self.caret, self.anchor));
            if self.undo.len() > 200 {
                self.undo.remove(0);
            }
        }
        self.redo.clear();
        self.typing = typing;
    }

    /// Ctrl+Z (`back`) or Ctrl+Y.
    pub fn undo(&mut self, ink: &Ink, back: bool, now: f64) {
        let (from, to) = if back { (&mut self.undo, &mut self.redo) } else { (&mut self.redo, &mut self.undo) };
        let Some((text, caret, anchor)) = from.pop() else { return };
        to.push((std::mem::replace(&mut self.text, text), self.caret, self.anchor));
        self.caret = caret.min(self.text.len());
        self.anchor = anchor.min(self.text.len());
        self.typing = false;
        self.goal_x = None;
        self.refit(ink, now);
    }

    /// Types `typed` over the selection.
    pub fn insert(&mut self, ink: &Ink, typed: &str, now: f64) {
        let single = typed.chars().count() == 1 && !typed.contains('\n');
        self.remember(single && self.caret == self.anchor);
        let (from, to) = self.selection();
        let typed: Vec<u16> = typed.encode_utf16().collect();
        self.text.splice(from..to, typed.iter().copied());
        self.caret = from + typed.len();
        self.anchor = self.caret;
        self.goal_x = None;
        self.refit(ink, now);
    }

    /// The words the editor opened with, `from`, become `to` while it still starts with them; what was typed after
    /// stays, and the caret with it.
    pub fn replace_prefix(&mut self, ink: &Ink, from: &str, to: &str, now: f64) -> bool {
        let from: Vec<u16> = from.encode_utf16().collect();
        let to: Vec<u16> = to.encode_utf16().collect();
        if from == to || !self.text.starts_with(&from) {
            return false;
        }
        let shift = |at: usize| if at >= from.len() { at + to.len() - from.len() } else { at.min(to.len()) };
        self.caret = shift(self.caret);
        self.anchor = shift(self.anchor);
        self.text.splice(..from.len(), to);
        self.refit(ink, now);
        true
    }

    /// Backspace (`forward` false) or Delete: the selection, or the character (`word`: the word) before or after the
    /// caret.
    pub fn erase(&mut self, ink: &Ink, forward: bool, word: bool, now: f64) {
        let (mut from, mut to) = self.selection();
        if from == to {
            match (forward, word) {
                (true, false) => to = self.next(to),
                (false, false) => from = self.previous(from),
                (true, true) => to = self.word_after(to),
                (false, true) => from = self.word_before(from),
            }
        }
        if from == to {
            return;
        }
        self.remember(false);
        self.text.drain(from..to);
        self.caret = from;
        self.anchor = from;
        self.goal_x = None;
        self.refit(ink, now);
    }

    /// The offset a character after `at` (a surrogate pair is one).
    fn next(&self, at: usize) -> usize {
        match self.text.get(at) {
            None => at,
            Some(&unit) if (0xD800..0xDC00).contains(&unit) => (at + 2).min(self.text.len()),
            Some(_) => at + 1,
        }
    }

    fn previous(&self, at: usize) -> usize {
        if at == 0 {
            return 0;
        }
        if at >= 2 && (0xDC00..0xE000).contains(&self.text[at - 1]) && (0xD800..0xDC00).contains(&self.text[at - 2]) {
            at - 2
        } else {
            at - 1
        }
    }

    /// Where the next word starts after `at` (Ctrl+Right): past the word or mark there, then past the space after it.
    fn word_after(&self, at: usize) -> usize {
        let mut at = at;
        if let Some(&unit) = self.text.get(at) {
            let first = kind(unit);
            at = self.next(at);
            if first != Kind::Space && first != Kind::Mark {
                while self.text.get(at).is_some_and(|&u| kind(u) == first) {
                    at = self.next(at);
                }
            }
        }
        while self.text.get(at).is_some_and(|&u| kind(u) == Kind::Space) {
            at = self.next(at);
        }
        at
    }

    /// Where the word before `at` starts (Ctrl+Left): back past space, then past the word or mark before it.
    fn word_before(&self, at: usize) -> usize {
        let mut at = at;
        while at > 0 && kind(self.text[at - 1]) == Kind::Space {
            at = self.previous(at);
        }
        if at > 0 {
            let last = kind(self.text[at - 1]);
            at = self.previous(at);
            if last != Kind::Mark {
                while at > 0 && kind(self.text[at - 1]) == last {
                    at = self.previous(at);
                }
            }
        }
        at
    }

    /// Ctrl+Left (`forward` false) or Ctrl+Right.
    pub fn word(&mut self, forward: bool, extend: bool, now: f64) {
        let at = if forward { self.word_after(self.caret) } else { self.word_before(self.caret) };
        self.goal_x = None;
        self.move_to(at, extend, now);
    }

    /// A double-click at (`x`, `y`): the word there is selected.
    pub fn select_word(&mut self, x: f32, y: f32, now: f64) {
        if self.composition.is_some() || self.text.is_empty() {
            return;
        }
        let at = self.offset_at(x, y).min(self.text.len() - 1);
        let k = kind(self.text[at]);
        let (mut from, mut to) = (at, self.next(at));
        if k != Kind::Mark {
            while from > 0 && kind(self.text[from - 1]) == k {
                from = self.previous(from);
            }
            while self.text.get(to).is_some_and(|&u| kind(u) == k) {
                to = self.next(to);
            }
        }
        self.anchor = from;
        self.goal_x = None;
        self.move_to(to, true, now);
        self.dragging = false;
    }

    fn move_to(&mut self, at: usize, extend: bool, now: f64) {
        self.typing = false;
        self.caret = at.min(self.text.len());
        if !extend {
            self.anchor = self.caret;
        }
        self.since = now;
        self.reveal_caret();
    }

    pub fn left(&mut self, extend: bool, now: f64) {
        let (from, to) = self.selection();
        let at = if from != to && !extend { from } else { self.previous(self.caret) };
        self.goal_x = None;
        self.move_to(at, extend, now);
    }

    pub fn right(&mut self, extend: bool, now: f64) {
        let (from, to) = self.selection();
        let at = if from != to && !extend { to } else { self.next(self.caret) };
        self.goal_x = None;
        self.move_to(at, extend, now);
    }

    /// Up (`lines` -1) or Down (1): the line above or below, at the same x.
    pub fn vertical(&mut self, lines: f32, extend: bool, now: f64) {
        let Some(layout) = self.layout.clone() else { return };
        let (x, top, height) = caret_at(&layout, self.caret as u32);
        let x = *self.goal_x.get_or_insert(x);
        let y = top + height / 2.0 + lines * height;
        let at = if y < 0.0 {
            0
        } else if y > self.content_height {
            self.text.len()
        } else {
            hit(&layout, x, y).0 as usize
        };
        self.move_to(at, extend, now);
    }

    /// Home (`end` false) or End: the start or end of the caret's line.
    pub fn line_edge(&mut self, end: bool, extend: bool, now: f64) {
        let Some(layout) = self.layout.clone() else { return };
        let mut at = self.caret;
        for (start, length) in crate::text::layout_lines(&layout) {
            let (start, length) = (start as usize, length as usize);
            if self.caret >= start && (self.caret < start + length || start + length == self.text.len()) {
                at = if end {
                    // Before the line's break, which belongs to it.
                    let mut stop = start + length;
                    while stop > start && matches!(self.text[stop - 1], 0x0A | 0x0D) {
                        stop -= 1;
                    }
                    stop
                } else {
                    start
                };
                break;
            }
        }
        self.goal_x = None;
        self.move_to(at, extend, now);
    }

    pub fn select_all(&mut self, now: f64) {
        self.anchor = 0;
        self.caret = self.text.len();
        self.since = now;
    }

    /// The offset at (`x`, `y`) on the overlay.
    fn offset_at(&self, x: f32, y: f32) -> usize {
        let Some(layout) = &self.layout else { return self.text.len() };
        let (top, _) = self.frame();
        let (at, _) = hit(layout, x - self.area.left, y - top + self.scroll_top);
        (at as usize).min(self.text.len())
    }

    /// A press at (`x`, `y`): the caret there, or the selection to there with Shift; a drag follows.
    pub fn press(&mut self, x: f32, y: f32, extend: bool, now: f64) {
        if self.composition.is_some() {
            return;
        }
        let at = self.offset_at(x, y);
        self.dragging = true;
        self.goal_x = None;
        self.move_to(at, extend, now);
    }

    pub fn drag(&mut self, x: f32, y: f32, now: f64) {
        if self.dragging {
            let at = self.offset_at(x, y);
            self.move_to(at, true, now);
        }
    }

    /// The wheel, `notches` toward the first line: a line a notch.
    pub fn wheel(&mut self, notches: f32) {
        let line = line_height(self.font_size) * self.area.scale;
        self.scroll_top =
            (self.scroll_top - notches * line).clamp(0.0, (self.content_height - self.shown_height).max(0.0));
    }

    /// The input method's composition so far, with its caret; empty when it ends.
    pub fn compose(&mut self, ink: &Ink, composition: Vec<u16>, caret: usize, now: f64) {
        if self.composition.is_none() && !composition.is_empty() {
            self.remember(false);
            // Composing replaces the selection.
            let (from, to) = self.selection();
            self.text.drain(from..to);
            self.caret = from;
            self.anchor = from;
        }
        self.composition = if composition.is_empty() { None } else { Some((composition, caret)) };
        self.refit(ink, now);
    }

    pub fn composing(&self) -> bool {
        self.composition.is_some()
    }

    /// The caret on the overlay, px: its x, top and height, for the input method's windows.
    pub fn caret_rect(&self) -> (f32, f32, f32) {
        let Some(layout) = &self.layout else { return (self.area.left, self.area.bottom, 0.0) };
        let (x, top, height) = caret_at(layout, self.shown_caret() as u32);
        let (frame_top, _) = self.frame();
        (self.area.left + x, frame_top + top - self.scroll_top, height)
    }

    pub fn draw(&mut self, ink: &Ink, now: f64) -> Result<()> {
        let Some(layout) = self.layout.clone() else { return Ok(()) };
        let layout = &layout;
        let (top, bottom) = self.frame();
        let origin = Vector2::new(self.area.left, top - self.scroll_top);
        let scale = self.area.scale;
        unsafe {
            ink.context.PushAxisAlignedClip(&rect(-1e6, top, 1e6, bottom), D2D1_ANTIALIAS_MODE_ALIASED);
        }
        let (from, to) = self.selection();
        if from != to && self.composition.is_none() {
            let selection = ink.brush(color(1.0, 1.0, 1.0, 0.25))?;
            for r in range_rects(layout, from as u32, (to - from) as u32) {
                unsafe {
                    ink.context.FillRectangle(
                        &rect(r.left + origin.X, r.top + origin.Y, r.right + origin.X, r.bottom + origin.Y),
                        &selection,
                    );
                }
            }
        }
        if let Some((composition, _)) = &self.composition {
            unsafe {
                let _ = layout.SetUnderline(
                    true,
                    DWRITE_TEXT_RANGE { startPosition: self.caret as u32, length: composition.len() as u32 },
                );
            }
        }
        let key = format!(
            "{}|{}|{}|{:?}|{}",
            origin.X,
            origin.Y,
            String::from_utf16_lossy(&self.text),
            self.composition.as_ref().map(|(c, at)| (String::from_utf16_lossy(c), *at, self.caret)),
            self.area.width
        );
        if self.baked.as_ref().is_none_or(|(baked, _)| *baked != key) {
            let words = ink.group(|context| unsafe {
                ink.white.SetOpacity(WORD_ALPHA);
                context.DrawTextLayout(origin, layout, &ink.white, D2D1_DRAW_TEXT_OPTIONS_NONE);
                ink.white.SetOpacity(1.0);
                Ok(())
            })?;
            self.baked = Some((key, ink.bake(&ink.with_halo(&words, HALO_SIGMA * scale, HALO_ALPHA)?)?));
        }
        if let Some((_, Some(words))) = &self.baked {
            ink.draw_baked(words, 1.0, None)?;
        }
        // The caret blinks, on from each change.
        if ((now - self.since) / BLINK_SECONDS) as u64 % 2 == 0 {
            let (x, caret_top, height) = caret_at(layout, self.shown_caret() as u32);
            let width = (1.0 * scale).round().max(1.0);
            let x = (origin.X + x).round();
            unsafe {
                ink.context.FillRectangle(
                    &rect(x, origin.Y + caret_top, x + width, origin.Y + caret_top + height),
                    &ink.white,
                );
            }
        }
        unsafe { ink.context.PopAxisAlignedClip() };
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn editor(text: &str) -> Editor {
        let mut editor = Editor::new();
        editor.text = text.encode_utf16().collect();
        editor
    }

    #[test]
    fn ctrl_arrows_move_a_word_at_a_time() {
        let e = editor("send it, then 帮我看一下。");
        let stops: Vec<usize> = std::iter::successors(Some(0), |&at| {
            let next = e.word_after(at);
            (next != at).then_some(next)
        })
        .collect();
        // "send ", "it", ", ", "then ", "帮我看一下", "。"
        assert_eq!(stops, vec![0, 5, 7, 9, 14, 19, 20]);
        assert_eq!(e.word_before(20), 19);
        assert_eq!(e.word_before(19), 14);
        assert_eq!(e.word_before(14), 9);
        assert_eq!(e.word_before(7), 5);
    }
}
