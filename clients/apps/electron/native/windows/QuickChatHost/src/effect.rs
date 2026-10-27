//! NameDrop's connection effect: every layer's value at a moment, which `effect.hlsl` draws at once. The macOS
//! QuickChatHost's NameDropEffect.swift times the same layers with the package's one spring (mass 2, stiffness 300,
//! damping 50, which is 1 - 3e^-10t + 2e^-15t); every constant here is that file's.

struct Tuning;
impl Tuning {
    const EXPOSURE: f32 = 0.85;
    const DIM: f32 = 0.8;
    const LIFT: f32 = 0.15;
    const BLUR: f32 = 1.1;
    const GLOW: f32 = 0.5;
    const RIDGE: f32 = 1.0;
    const REFRACTION: f32 = 1.0;
    const RECOIL_DAMPING: f32 = 0.4;
    const CHROMA: f32 = 1.0;
    const TEMPO: f32 = 2.2;
    const LIGHT: f32 = 0.5;
}

/// The wave's pace against the rest of the shockwave.
const RISE: f32 = 0.99 / (Tuning::LIGHT * Tuning::TEMPO);
/// From the shockwave's start until everything is gone, in seconds.
pub const SEND_DURATION: f64 = (2.48 + 1.5) / Tuning::TEMPO as f64;
pub const CANCEL_DURATION: f64 = 0.8 / Tuning::TEMPO as f64;
const HOLD_DARKNESS: f32 = 1.0 - Tuning::EXPOSURE * (1.0 - 0.5 * Tuning::DIM);
const LIFT_SPEED: f32 = 0.936;
const RIDGE_FROM: f32 = -0.18;
const RIDGE_TO: f32 = 0.34;

fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
/// The package's spring as a value: 0 at `begin`, settling at 1; `time` on its timeline (seconds × tempo).
fn spring(time: f32, begin: f32, speed: f32) -> f32 {
    let local = (time - begin).max(0.0) * 0.7 * speed;
    (1.0 - 3.0 * (-10.0 * local).exp() + 2.0 * (-15.0 * local).exp()).clamp(0.0, 1.0)
}
/// The recoil's underdamped spring, its natural frequency kept and its damping ratio `RECOIL_DAMPING`.
fn bounce(time: f32, begin: f32, speed: f32) -> f32 {
    let local = (time - begin).max(0.0) * 0.7 * speed;
    let natural = 12.24745_f32;
    let decay = Tuning::RECOIL_DAMPING * natural;
    let frequency = natural * (1.0 - Tuning::RECOIL_DAMPING * Tuning::RECOIL_DAMPING).sqrt();
    1.0 - (-decay * local).exp() * ((frequency * local).cos() + decay / frequency * (frequency * local).sin())
}
/// The settling ends: the scene clears from 2.48 seconds in.
fn cleanup(t: f32) -> f32 {
    if t < 2.48 {
        0.0
    } else {
        spring(t - 2.48, 0.0, 0.342)
    }
}
/// What is left goes over the package's last 0.2 seconds.
fn removal(t: f32) -> f32 {
    1.0 - smoothstep(2.48 + 1.3, 2.48 + 1.5, t)
}
/// A rising light's share by how far it has come: gone by 85% of the way.
fn gone_before(travel: f32) -> f32 {
    1.0 - smoothstep(0.5, 0.85, travel)
}
/// The package's lights come up over 0.12 seconds of its timeline.
fn ramp_in(t: f32) -> f32 {
    smoothstep(0.0, 0.12, t)
}
/// The ridge's refraction fades as it travels; `time` is the wave's.
fn ridge_presence(time: f32) -> f32 {
    1.0 - spring(time, 0.105, 0.46)
}
fn mix(a: f32, b: f32, k: f32) -> f32 {
    a + (b - a) * k
}
fn between(a: [f32; 2], b: [f32; 2], k: f32) -> [f32; 2] {
    [mix(a[0], b[0], k), mix(a[1], b[1], k)]
}

/// Every layer's value at one moment, as `effect.hlsl`'s constant buffer lays it out.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Values {
    pub size: [f32; 2],
    pub has_screen: f32,
    pub max_lod: f32,
    pub stage: [f32; 3],
    pub lift: f32,
    pub blur: f32,
    pub backdrop: f32,
    pub shocking: f32,
    pub dim: f32,
    pub shock: [f32; 4],
    pub band: [f32; 3],
    pub rainbow_blur: f32,
    pub circle: [f32; 4],
    pub rainbow: [f32; 4],
    pub dark_arc: [f32; 4],
    pub ridge_glow: [f32; 3],
    pub pad0: f32,
    pub shock_sheen: [f32; 3],
    pub pad1: f32,
    pub hint: [f32; 4],
    pub hint_move: [f32; 2],
    pub pad2: [f32; 2],
}

#[derive(Clone, Copy)]
enum Phase {
    Idle,
    Present { at: f64 },
    Send { at: f64, from: Values, lifted: f32 },
    Cancel { at: f64, from: Values },
}

pub struct Effect {
    phase: Phase,
    presented_at: f64,
    voice: f32,
    width: f32,
    height: f32,
    stage_left: f32,
    stage_width: f32,
    stage_height: f32,
}

impl Default for Effect {
    fn default() -> Self {
        Self {
            phase: Phase::Idle,
            presented_at: 0.0,
            voice: 0.0,
            width: 1.0,
            height: 1.0,
            stage_left: 0.0,
            stage_width: 1.0,
            stage_height: 1.0,
        }
    }
}

impl Effect {
    /// The overlay in device px, and how wide the package's canvas is drawn, centered at the screen's bottom.
    pub fn layout(&mut self, width: f32, height: f32, stage_width: f32) {
        self.width = width;
        self.height = height;
        self.stage_width = stage_width;
        self.stage_height = 2556.0 * stage_width / 1179.0;
        self.stage_left = (width - stage_width) / 2.0;
    }

    /// The connection hint: the bottom of the screen dims, softens and lifts, and glows rise from the taskbar.
    pub fn present(&mut self, now: f64) {
        self.phase = Phase::Present { at: now };
        self.presented_at = now;
        self.voice = 0.0;
    }

    /// The voice's loudness, 0…1, already smoothed; brightens the glow at the taskbar.
    pub fn set_voice_level(&mut self, level: f32) {
        self.voice = level;
    }

    /// The shockwave.
    pub fn send(&mut self, now: f64) {
        let from = self.values(now, false, 0.0);
        let lifted = Tuning::LIFT * spring(((now - self.presented_at) as f32) * Tuning::TEMPO, 0.0, LIFT_SPEED);
        self.phase = Phase::Send { at: now, from, lifted };
    }

    /// The hint falls back.
    pub fn cancel(&mut self, now: f64) {
        let from = self.values(now, false, 0.0);
        self.phase = Phase::Cancel { at: now, from };
    }

    /// Whether a send or cancel has finished at `now`, or nothing shows.
    #[cfg(test)]
    pub fn finished(&self, now: f64) -> bool {
        match self.phase {
            Phase::Send { at, .. } => now - at >= SEND_DURATION,
            Phase::Cancel { at, .. } => now - at >= CANCEL_DURATION,
            Phase::Idle => true,
            Phase::Present { .. } => false,
        }
    }

    pub fn reset(&mut self) {
        self.phase = Phase::Idle;
    }

    fn point(&self, x: f32, y: f32) -> [f32; 2] {
        let scale = self.stage_width / 1179.0;
        [self.stage_left + x * scale, (2556.0 - y) * scale]
    }

    /// Every layer's value at `now`, with whether there is a screen behind and its mips.
    pub fn values(&self, now: f64, has_screen: bool, max_lod: f32) -> Values {
        let scale = self.stage_width / 1179.0;
        let still = Values {
            size: [self.width, self.height],
            has_screen: if has_screen { 1.0 } else { 0.0 },
            max_lod,
            stage: [self.stage_left, self.stage_width, self.stage_height],
            backdrop: 1.0,
            circle: [0.0, 0.0, 1.0, 0.0],
            rainbow: [0.0, 0.0, 1.0, 0.0],
            dark_arc: [0.0, 0.0, 1.0, 0.0],
            hint_move: [self.point(589.0, 694.5)[1], 0.0],
            ..Default::default()
        };
        let with = |mut v: Values| {
            v.size = still.size;
            v.has_screen = still.has_screen;
            v.max_lod = still.max_lod;
            v.stage = still.stage;
            v
        };
        match self.phase {
            Phase::Idle => still,
            Phase::Present { at } => {
                let t = ((now - at) as f32) * Tuning::TEMPO;
                Values {
                    lift: Tuning::LIFT * spring(t, 0.0, LIFT_SPEED),
                    // A variable blur's σ is twice its radius: the package's 8 units where its mask is full.
                    blur: 8.0 * scale * spring(t, 0.0, 0.64),
                    dim: HOLD_DARKNESS * spring(t, 0.0, 0.4),
                    hint: [
                        0.346357 * Tuning::GLOW * spring(t, 0.0, 0.76),
                        0.75 * Tuning::GLOW * spring(t, 0.0, 0.592),
                        self.voice * 0.55 * Tuning::GLOW,
                        0.4 * Tuning::GLOW * spring(t, 0.0, 0.596),
                    ],
                    hint_move: [
                        mix(self.point(589.0, 694.5)[1], self.point(589.0, 2385.5)[1], spring(t, 0.0, 0.602)),
                        0.0,
                    ],
                    ..still
                }
            }
            Phase::Cancel { at, from } => {
                let k = spring(((now - at) as f32) * Tuning::TEMPO, 0.0, 1.4);
                with(Values {
                    lift: from.lift * (1.0 - k),
                    blur: from.blur * (1.0 - k),
                    backdrop: from.backdrop * (1.0 - k),
                    dim: from.dim * (1.0 - k),
                    hint: from.hint.map(|value| value * (1.0 - k)),
                    hint_move: [from.hint_move[0], mix(from.hint_move[1], -40.0 * scale, k)],
                    ..from
                })
            }
            Phase::Send { at, from, lifted } => with(self.shock(((now - at) as f32) * Tuning::TEMPO, from, lifted)),
        }
    }

    /// The shockwave at `t` on the package's timeline, from the hint's values `from`.
    fn shock(&self, t: f32, from: Values, lifted: f32) -> Values {
        let wave = t * RISE;
        let scale = self.stage_width / 1179.0;
        let fringe = 0.858 * 0.0026 * Tuning::CHROMA * Tuning::REFRACTION * self.stage_height;
        // The dim deepens to full, lightens behind the wave, then lifts.
        let held = from.dim / HOLD_DARKNESS;
        let on = held.max(spring(t, 0.0, 1.1)) * (1.0 - cleanup(t)) * removal(t);
        let dim = (0.5 + (0.123 - 0.5) * spring(t, 0.36, 0.5)) * on * Tuning::DIM;
        let arc_scale = mix(0.72, 4.14, spring(wave, 0.105, 1.0));
        let arc_opacity = Tuning::RIDGE * ramp_in(wave) * (1.0 - spring(wave, 0.15, 0.652));
        let hint_fade = 1.0 - smoothstep(0.1, 0.6, spring(t, 0.0, 0.3));
        let ridge_travel = spring(wave, 0.105, 1.068);
        let rainbow = between(self.point(589.5, 2612.0), self.point(575.5, 1908.0), spring(wave, 0.105, 1.0));
        let dark_arc = between(self.point(589.5, 2612.0), self.point(589.5, 1635.0), spring(wave, 0.105, 1.044));
        let ridge_glow = between(self.point(589.5, 2866.5), self.point(589.5, 1572.5), spring(wave, 0.105, 0.828));
        let shock_sheen = between(self.point(589.0, 1794.5), self.point(589.0, 1243.5), spring(wave, 0.26, 1.0));
        let circle = self.point(589.5, 2768.0);
        Values {
            lift: lifted * (1.0 - spring(t, 0.0, 1.0)),
            blur: from.blur * (1.0 - spring(t, 0.0, 1.0)),
            backdrop: (1.0 - cleanup(t)) * removal(t),
            shocking: 1.0,
            shock: [
                RIDGE_FROM + (RIDGE_TO - RIDGE_FROM) * ridge_travel,
                ridge_presence(wave),
                0.12 + 0.16 * bounce(t, 0.105, 0.7) + 0.035 * spring(t, 0.105, 0.3),
                spring(t, 0.105, 3.0) * (1.0 - cleanup(t)),
            ],
            band: [
                mix(RIDGE_FROM, RIDGE_TO, ridge_travel) * self.stage_height,
                (0.875 * Tuning::BLUR).min(1.0) * (1.0 - spring(wave, 0.13, 0.46)) * removal(t),
                fringe * ridge_presence(wave),
            ],
            dim: 1.0 - (1.0 - (1.0 - Tuning::EXPOSURE) * on) * (1.0 - dim.min(1.0)),
            // The light that blooms from the bottom edge.
            circle: [
                circle[0],
                circle[1],
                mix(0.81, 4.53, spring(wave, 0.105, 1.0)),
                0.681387 * Tuning::RIDGE * ramp_in(wave) * (1.0 - spring(wave, 0.105, 0.652)),
            ],
            // The eclipse: a rainbow arc dodging what is behind, over a dark arc.
            rainbow: [rainbow[0], rainbow[1], arc_scale, arc_opacity],
            // Blurring as it rises, to 5 canvas units (NameDropEffect.swift's gaussianBlur).
            rainbow_blur: 5.0 * scale * spring(wave, 0.25, 1.0),
            dark_arc: [dark_arc[0], dark_arc[1], arc_scale, arc_opacity],
            // The ridge's own light and its chromatic sheen, gone before they arrive.
            ridge_glow: [
                ridge_glow[0],
                ridge_glow[1],
                0.629671
                    * Tuning::RIDGE
                    * ramp_in(wave)
                    * (1.0 - spring(wave, 0.105, 0.808))
                    * gone_before(spring(wave, 0.105, 0.828)),
            ],
            shock_sheen: [
                shock_sheen[0],
                shock_sheen[1],
                0.5 * Tuning::RIDGE
                    * spring(wave, 0.105, 1.0)
                    * (1.0 - spring(wave, 0.315, 0.5))
                    * gone_before(spring(wave, 0.26, 1.0)),
            ],
            // The hint's glows are gone part way down.
            hint: [
                from.hint[0] * hint_fade,
                from.hint[1] * hint_fade,
                from.hint[2] * (1.0 - smoothstep(0.0, 0.2, t)),
                from.hint[3] * hint_fade,
            ],
            hint_move: [
                mix(from.hint_move[0], self.point(589.0, 2263.81)[1], spring(t, 0.0, 1.0)),
                mix(from.hint_move[1], -1703.0 * scale, spring(t, 0.0, 0.3)),
            ],
            ..Values::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_values_fill_the_constant_buffer_in_whole_registers() {
        assert_eq!(std::mem::size_of::<Values>() % 16, 0);
        assert_eq!(std::mem::size_of::<Values>(), 16 * 12);
    }

    #[test]
    fn a_send_and_a_cancel_end_and_the_hint_settles() {
        let mut effect = Effect::default();
        effect.layout(3840.0, 2157.0, 750.0);
        effect.present(0.0);
        let held = effect.values(3.0, true, 11.0);
        assert!((held.dim - HOLD_DARKNESS).abs() < 1e-3);
        effect.cancel(3.0);
        assert!(!effect.finished(3.1));
        assert!(effect.finished(3.001 + CANCEL_DURATION));
        effect.present(10.0);
        effect.send(11.0);
        assert!(effect.finished(11.001 + SEND_DURATION));
    }
}
