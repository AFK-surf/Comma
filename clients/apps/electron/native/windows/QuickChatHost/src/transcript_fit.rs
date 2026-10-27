//! How Quick Chat's words fill their box, as the macOS QuickChatCore's TranscriptFit and TranscriptScroll: at the
//! largest size while they fit, then smaller as they grow, then at the smallest size taller than the box, scrolled.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fit {
    pub font_size: f32,
    /// How far the text at `font_size` is taller than the box.
    pub overflow: f32,
}

/// The largest size, in half-pixel steps from `minimum` to `maximum`, whose text is no taller than `height`.
/// `text_height` grows with the size, because a larger size wraps into more and taller lines.
pub fn fit_transcript(height: f32, maximum: f32, minimum: f32, mut text_height: impl FnMut(f32) -> f32) -> Fit {
    const STEP: f32 = 0.5;
    if text_height(maximum) <= height {
        return Fit { font_size: maximum, overflow: 0.0 };
    }
    let smallest = text_height(minimum);
    if smallest > height {
        return Fit { font_size: minimum, overflow: smallest - height };
    }
    // `low` fits and `high` does not, both counted in steps above `minimum`.
    let (mut low, mut high) = (0i32, ((maximum - minimum) / STEP).ceil() as i32);
    while high - low > 1 {
        let middle = (low + high) / 2;
        if text_height(minimum + middle as f32 * STEP) <= height {
            low = middle;
        } else {
            high = middle;
        }
    }
    Fit { font_size: minimum + low as f32 * STEP, overflow: 0.0 }
}

/// Where text taller than its box is scrolled. It follows the last line as words arrive. Scrolled back, it keeps the
/// lines being read in place while the text grows below them, until it is scrolled to the end again.
#[derive(Default, Clone, Copy, Debug)]
pub struct TranscriptScroll {
    /// How far the text is taller than the box.
    pub overflow: f32,
    /// How far the text is scrolled back from its last line, from 0 to `overflow`.
    pub offset: f32,
}

impl TranscriptScroll {
    /// The text changed and is now `overflow` taller than the box.
    pub fn set_overflow(&mut self, overflow: f32) {
        let next = overflow.max(0.0);
        // The text grows at the bottom: scrolling back by as much keeps the lines in place.
        if self.offset > 0.0 {
            self.offset = (self.offset + next - self.overflow).max(0.0).min(next);
        }
        self.overflow = next;
    }

    /// A positive `delta` scrolls back toward the first line.
    pub fn scroll(&mut self, delta: f32) {
        self.offset = (self.offset + delta).max(0.0).min(self.overflow);
    }

    /// How much of the text is out of the box above it.
    pub fn hidden_above(&self) -> f32 {
        self.overflow - self.offset
    }

    /// How much of the text is out of the box below it.
    pub fn hidden_below(&self) -> f32 {
        self.offset
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Text whose height is `lines(size)` lines of `size × 1.3`, in a box 117 high, from 30 down to 17.
    fn fit(lines: impl Fn(f32) -> f32) -> Fit {
        fit_transcript(117.0, 30.0, 17.0, |size| lines(size) * size * 1.3)
    }

    #[test]
    fn short_text_stays_largest() {
        assert_eq!(fit(|_| 1.0), Fit { font_size: 30.0, overflow: 0.0 });
    }

    #[test]
    fn longer_text_shrinks_to_the_largest_size_that_fits() {
        let wrapped = |size: f32| (120.0 / (720.0 / size)).ceil();
        let result = fit(wrapped);
        assert_eq!(result.overflow, 0.0);
        assert!(result.font_size < 30.0 && result.font_size >= 17.0);
        let next = result.font_size + 0.5;
        assert!(wrapped(next) * next * 1.3 > 117.0);
    }

    #[test]
    fn text_beyond_the_smallest_size_overflows() {
        let result = fit(|_| 12.0);
        assert_eq!(result.font_size, 17.0);
        assert!((result.overflow - (12.0 * 17.0 * 1.3 - 117.0)).abs() < 1e-3);
    }

    #[test]
    fn the_scroll_keeps_the_lines_being_read() {
        let mut scroll = TranscriptScroll::default();
        scroll.set_overflow(47.0);
        scroll.scroll(100.0);
        assert_eq!((scroll.offset, scroll.hidden_above()), (47.0, 0.0));
        scroll.set_overflow(67.0);
        assert_eq!((scroll.hidden_above(), scroll.hidden_below()), (0.0, 67.0));
        scroll.scroll(-30.0);
        scroll.set_overflow(87.0);
        assert_eq!(scroll.hidden_above(), 30.0);
        scroll.scroll(-200.0);
        scroll.set_overflow(107.0);
        assert_eq!(scroll.offset, 0.0);
    }
}
