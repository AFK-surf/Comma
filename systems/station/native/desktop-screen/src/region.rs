// A part of the display a view frames alone (a client zoomed in: docs/remote-screens.md, "Regions"): as the station
// says it in `bounds`, and cut from a picture on even pixels (what 4:2:0 crops at), said back as the part it is.
use serde_json::{Value, json};

/// x, y, w, h: 0..1 of the display.
pub type Region = [f64; 4];

/// The part a `bounds` message says (`region`), within the display and at least a 50th of it each way; None for none.
pub fn of(v: &Value) -> Option<Region> {
    let n = |k: &str| v[k].as_f64().filter(|f| f.is_finite());
    let (x, y, w, h) = (n("x")?, n("y")?, n("w")?, n("h")?);
    let (w, h) = (w.clamp(0.02, 1.0), h.clamp(0.02, 1.0));
    Some([x.clamp(0.0, 1.0 - w), y.clamp(0.0, 1.0 - h), w, h])
}

/// `region` of a picture `width`×`height` in its pixels (left, top, width, height, on even ones), and that rectangle as
/// the part of the picture it is.
pub fn crop(region: Region, width: u32, height: u32) -> ((u32, u32, u32, u32), Region) {
    let even = |v: f64| (v.round().max(0.0) as u32) & !1;
    let (x, y) = (even(region[0] * width as f64).min(width.saturating_sub(2)), even(region[1] * height as f64).min(height.saturating_sub(2)));
    let w = even(region[2] * width as f64).clamp(2, width - x);
    let h = even(region[3] * height as f64).clamp(2, height - y);
    let r4 = |v: f64| (v * 10000.0).round() / 10000.0;
    ((x, y, w, h), [r4(x as f64 / width as f64), r4(y as f64 / height as f64), r4(w as f64 / width as f64), r4(h as f64 / height as f64)])
}

/// Message 7's JSON: the part the frames from the next one on show (null: the whole display).
pub fn said(part: Option<Region>) -> Value {
    match part {
        Some([x, y, w, h]) => json!({ "region": { "x": x, "y": y, "w": w, "h": h } }),
        None => json!({ "region": null }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_part_is_kept_within_the_display() {
        assert_eq!(of(&json!({ "x": 0.9, "y": -1, "w": 0.5, "h": 0.001 })), Some([0.5, 0.0, 0.5, 0.02]));
        assert_eq!(of(&json!(null)), None);
        assert_eq!(of(&json!({ "x": 0.1 })), None);
    }

    #[test]
    fn cut_on_even_pixels_and_said_as_it_was_cut() {
        // A quarter in the middle of 2560×1440.
        let (rect, part) = crop([0.375, 0.375, 0.25, 0.25], 2560, 1440);
        assert_eq!(rect, (960, 540, 640, 360));
        assert_eq!(part, [0.375, 0.375, 0.25, 0.25]);
        // Odd pixels rounded down to even ones, and the part said as cut.
        let (rect, part) = crop([0.1, 0.1, 0.5, 0.5], 1001, 999);
        assert_eq!(rect, (100, 100, 500, 500));
        assert_eq!(part, [0.0999, 0.1001, 0.4995, 0.5005]);
    }
}
