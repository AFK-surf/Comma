//! Quick Chat's two round buttons under the words, as the overlay page drew them (SF Symbols' xmark and arrow.up at
//! 13 pt, as on macOS): close, dark and translucent, and send, nearly white, dim while there is nothing to send. Each
//! lightens under the pointer and shrinks a little while pressed, in 0.12 s. And the tip, a small line above the words
//! that rises into place out of a slight blur as it fades in.

use windows::core::{Interface, Result};
use windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F;
use windows::Win32::Graphics::Direct2D::{
    ID2D1Brush, ID2D1Geometry, D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_ELLIPSE,
};
use windows::Win32::Graphics::DirectWrite::{IDWriteTextLayout, DWRITE_TEXT_METRICS};
use windows_numerics::{Matrix3x2, Vector2};

use crate::motion::settle;
use crate::text::{color, layout_height, Ink};

const SIZE: f32 = 32.0;
const GAP: f32 = 12.0;
const ICON: f32 = 13.0;
const STROKE: f32 = 1.9;
const TRANSITION: f32 = 0.12;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Button {
    Close,
    Send,
}

#[derive(Default)]
struct Look {
    hover: f32,
    pressed: f32,
    disabled: f32,
}

pub struct Controls {
    /// The buttons' center on the overlay, px, and the scale.
    center: Vector2,
    scale: f32,
    pub shown: bool,
    pub send_enabled: bool,
    pub hover: Option<Button>,
    pub pressed: Option<Button>,
    close: Look,
    send: Look,
    last: f64,
}

impl Controls {
    pub fn new() -> Self {
        Self {
            center: Vector2::default(),
            scale: 1.0,
            shown: false,
            send_enabled: false,
            hover: None,
            pressed: None,
            close: Look::default(),
            send: Look { disabled: 1.0, ..Default::default() },
            last: 0.0,
        }
    }

    /// The buttons' middle at `x`, `bottom` px above the overlay's bottom edge... as px on the overlay.
    pub fn place(&mut self, x: f32, y: f32, scale: f32) {
        self.center = Vector2::new(x, y);
        self.scale = scale;
    }

    fn button_center(&self, button: Button) -> Vector2 {
        let offset = (SIZE + GAP) / 2.0 * self.scale;
        match button {
            Button::Close => Vector2::new(self.center.X - offset, self.center.Y),
            Button::Send => Vector2::new(self.center.X + offset, self.center.Y),
        }
    }

    /// The button at (`x`, `y`) on the overlay.
    pub fn at(&self, x: f32, y: f32) -> Option<Button> {
        if !self.shown {
            return None;
        }
        let radius = SIZE / 2.0 * self.scale;
        [Button::Close, Button::Send].into_iter().find(|&button| {
            let c = self.button_center(button);
            (x - c.X).powi(2) + (y - c.Y).powi(2) <= radius * radius
        })
    }

    pub fn draw(&mut self, ink: &Ink, now: f64) -> Result<()> {
        // Each look moves toward where it is going, all of the way in 0.12 s.
        let step = (((now - self.last) as f32) / TRANSITION).clamp(0.0, 1.0);
        self.last = now;
        let towards = |value: &mut f32, target: bool| {
            let target = if target { 1.0 } else { 0.0 };
            *value += (target - *value).clamp(-step, step);
        };
        for (button, look) in [(Button::Close, &mut self.close), (Button::Send, &mut self.send)] {
            let enabled = button == Button::Close || self.send_enabled;
            towards(&mut look.hover, self.hover == Some(button) && enabled);
            towards(&mut look.pressed, self.pressed == Some(button) && self.hover == Some(button) && enabled);
            towards(&mut look.disabled, !enabled);
        }
        if !self.shown {
            return Ok(());
        }
        let s = self.scale;
        for button in [Button::Close, Button::Send] {
            let look = if button == Button::Close { &self.close } else { &self.send };
            let center = self.button_center(button);
            let (fill, border, ink_color, icon): (D2D1_COLOR_F, Option<D2D1_COLOR_F>, D2D1_COLOR_F, &[&[(f32, f32)]]) =
                match button {
                    Button::Close => (
                        color(0.0, 0.0, 0.0, 0.32 + 0.12 * look.hover),
                        Some(color(1.0, 1.0, 1.0, 0.14)),
                        color(1.0, 1.0, 1.0, 0.86),
                        &[&[(2.4, 2.4), (10.6, 10.6)], &[(10.6, 2.4), (2.4, 10.6)]],
                    ),
                    Button::Send => (
                        color(1.0, 1.0, 1.0, 0.9 + 0.1 * look.hover),
                        None,
                        color(0.0, 0.0, 0.0, 0.85),
                        &[&[(6.5, 11.6), (6.5, 1.6)], &[(2.2, 5.9), (6.5, 1.6), (10.8, 5.9)]],
                    ),
                };
            let opacity = 1.0 - 0.65 * look.disabled;
            let zoom = 1.0 - 0.06 * look.pressed;
            let drawing = ink.group(|context| unsafe {
                context.SetTransform(
                    &(Matrix3x2::translation(-center.X, -center.Y)
                        * Matrix3x2 { M11: zoom, M12: 0.0, M21: 0.0, M22: zoom, M31: 0.0, M32: 0.0 }
                        * Matrix3x2::translation(center.X, center.Y)),
                );
                let radius = SIZE / 2.0 * s;
                let ellipse = D2D1_ELLIPSE { point: center, radiusX: radius, radiusY: radius };
                context.FillEllipse(&ellipse, &ink.brush(fill)?);
                if let Some(border) = border {
                    let half = 0.25 * s;
                    let inner = D2D1_ELLIPSE { point: center, radiusX: radius - half, radiusY: radius - half };
                    context.DrawEllipse(&inner, &ink.brush(border)?, 0.5 * s, None);
                }
                let stroke = ink.round_stroke()?;
                let brush = ink.brush(ink_color)?;
                let origin = Vector2::new(center.X - ICON / 2.0 * s, center.Y - ICON / 2.0 * s);
                for line in icon {
                    let points: Vec<Vector2> =
                        line.iter().map(|&(x, y)| Vector2::new(origin.X + x * s, origin.Y + y * s)).collect();
                    let path = ink.polyline(&points)?;
                    context.DrawGeometry(&path.cast::<ID2D1Geometry>()?, &brush, STROKE * s, &stroke);
                }
                Ok(())
            })?;
            ink.draw_image(&drawing, opacity, None)?;
        }
        Ok(())
    }
}

const TIP_SIZE: f32 = 11.0;
const TIP_SHOW: f64 = 0.32;
const TIP_HIDE: f64 = 0.12;

/// A line above the words: what is happening, or how to go on.
pub struct Tip {
    text: String,
    layout: Option<IDWriteTextLayout>,
    shown_since: Option<f64>,
    hidden_since: Option<f64>,
}

impl Tip {
    pub fn new() -> Self {
        Self { text: String::new(), layout: None, shown_since: None, hidden_since: None }
    }

    pub fn shown(&self) -> bool {
        self.shown_since.is_some() && self.hidden_since.is_none()
    }

    /// Shows `text`; appearing, it rises 4 px into place, out of a slight blur, as it fades in.
    pub fn show(&mut self, text: &str, now: f64) {
        if text != self.text {
            self.text = text.to_string();
            self.layout = None;
        }
        if !self.shown() {
            self.shown_since = Some(now);
            self.hidden_since = None;
        }
    }

    pub fn hide(&mut self, now: f64) {
        if self.shown() {
            self.hidden_since = Some(now);
        }
    }

    pub fn clear(&mut self) {
        self.shown_since = None;
        self.hidden_since = None;
    }

    /// Draws it centered at `x`, its bottom at `bottom` px.
    pub fn draw(&mut self, ink: &Ink, x: f32, bottom: f32, scale: f32, now: f64) -> windows::core::Result<()> {
        let Some(since) = self.shown_since else { return Ok(()) };
        let (opacity, rise, blur) = match self.hidden_since {
            Some(hidden) => {
                let fade = 1.0 - ((now - hidden) / TIP_HIDE).min(1.0) as f32;
                if fade <= 0.0 {
                    self.clear();
                    return Ok(());
                }
                (fade, 0.0, 0.0)
            }
            None => {
                let k = settle(now - since, TIP_SHOW);
                (k, 4.0 * (1.0 - k), 3.0 * (1.0 - k))
            }
        };
        if self.layout.is_none() {
            let size = TIP_SIZE * scale;
            let format = ink.format(size, (size * 1.3).round(), true)?;
            let text: Vec<u16> = self.text.encode_utf16().collect();
            self.layout = Some(ink.layout(&text, &format, 2000.0 * scale)?);
        }
        let layout = self.layout.clone().unwrap();
        let mut metrics = DWRITE_TEXT_METRICS::default();
        unsafe { layout.GetMetrics(&mut metrics)? };
        let height = layout_height(&layout);
        let origin = Vector2::new(x - 1000.0 * scale, bottom - height + rise * scale);
        let words = ink.group(|context| unsafe {
            ink.white.SetOpacity(0.6);
            context.DrawTextLayout(origin, &layout, &ink.white, D2D1_DRAW_TEXT_OPTIONS_NONE);
            ink.white.SetOpacity(1.0);
            Ok(())
        })?;
        let words = ink.with_halo(&words, 4.0 * scale, 0.6)?;
        ink.draw_image(&ink.blurred(&words, blur * scale)?, opacity, None::<&ID2D1Brush>)
    }
}
