//! The curves Quick Chat's text moves on, as the overlay page animated it.

/// The package's spring (mass 2, stiffness 300, damping 50, which is 1 - 3e^-10t + 2e^-15t) at `speed`: how far it
/// has gone `elapsed` seconds after it began, 0…1; settled (1) once its own time reaches 0.8.
pub fn spring(elapsed: f64, speed: f64) -> f32 {
    if elapsed <= 0.0 {
        return 0.0;
    }
    let local = elapsed * 0.7 * speed;
    if local >= 0.8 {
        return 1.0;
    }
    (1.0 - 3.0 * (-10.0 * local).exp() + 2.0 * (-15.0 * local).exp()) as f32
}

/// CSS's `cubic-bezier(x1, y1, x2, y2)` at `t` (0…1 of the time).
pub fn cubic_bezier(x1: f64, y1: f64, x2: f64, y2: f64, t: f64) -> f32 {
    let t = t.clamp(0.0, 1.0);
    let curve = |a: f64, b: f64, s: f64| 3.0 * a * s * (1.0 - s).powi(2) + 3.0 * b * s * s * (1.0 - s) + s.powi(3);
    // The curve's parameter whose x is `t`, by bisection: x grows with it.
    let (mut low, mut high) = (0.0, 1.0);
    for _ in 0..30 {
        let middle = (low + high) / 2.0;
        if curve(x1, x2, middle) < t {
            low = middle;
        } else {
            high = middle;
        }
    }
    curve(y1, y2, (low + high) / 2.0) as f32
}

/// Quick Chat's quick settle, `cubic-bezier(0.23, 1, 0.32, 1)`, `elapsed` seconds into `duration`.
pub fn settle(elapsed: f64, duration: f64) -> f32 {
    cubic_bezier(0.23, 1.0, 0.32, 1.0, elapsed / duration)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_curves_start_at_0_and_end_at_1() {
        assert_eq!(spring(0.0, 1.0), 0.0);
        assert_eq!(spring(10.0, 1.0), 1.0);
        assert!(spring(0.2, 1.0) > 0.3 && spring(0.2, 1.0) < 1.0);
        assert!(settle(0.0, 1.0).abs() < 1e-3);
        assert!((settle(1.0, 1.0) - 1.0).abs() < 1e-3);
        assert!(settle(0.3, 1.0) > 0.8);
        assert!((cubic_bezier(0.0, 0.0, 1.0, 1.0, 0.4) - 0.4).abs() < 1e-3);
    }
}
