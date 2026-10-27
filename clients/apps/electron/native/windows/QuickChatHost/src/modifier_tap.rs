//! Taps of one modifier (Ctrl unless the person chose another), as QuickChatCore's ModifierTap recognizes them on
//! macOS: the modifier pressed and released within `MAXIMUM_PRESS_MS`, with no other key, click or scroll meanwhile.
//! It fires on the release. A second tap that starts within `MAXIMUM_GAP_MS` of the first one's release is a double
//! tap.

pub const MAXIMUM_PRESS_MS: f64 = 400.0;
pub const MAXIMUM_GAP_MS: f64 = 400.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Input {
    /// The modifier went down (repeats while held change nothing).
    Down,
    Up,
    /// Any other key, a click or a scroll.
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tap {
    Single,
    Double,
}

#[derive(Default)]
pub struct Recognizer {
    pressed_at: Option<f64>,
    /// The release of a single tap that a second one can still complete.
    released_at: Option<f64>,
}

impl Recognizer {
    /// Feeds one input at `time` (ms); returns the tap it completes.
    pub fn handle(&mut self, input: Input, time: f64) -> Option<Tap> {
        match input {
            Input::Down => {
                // A held key repeats its key-down; the press began at the first.
                self.pressed_at.get_or_insert(time);
                None
            }
            Input::Up => {
                let pressed_at = self.pressed_at.take()?;
                if time - pressed_at > MAXIMUM_PRESS_MS {
                    self.released_at = None;
                    return None;
                }
                if let Some(first) = self.released_at {
                    if pressed_at - first <= MAXIMUM_GAP_MS {
                        self.released_at = None;
                        return Some(Tap::Double);
                    }
                }
                self.released_at = Some(time);
                Some(Tap::Single)
            }
            Input::Other => {
                // A chord such as Ctrl+C, or anything between two taps.
                self.pressed_at = None;
                self.released_at = None;
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(inputs: &[(Input, f64)]) -> Vec<Tap> {
        let mut recognizer = Recognizer::default();
        inputs.iter().filter_map(|&(input, time)| recognizer.handle(input, time)).collect()
    }

    #[test]
    fn two_quick_taps_are_a_double_tap() {
        use Input::*;
        let taps = feed(&[(Down, 0.0), (Up, 80.0), (Down, 200.0), (Up, 260.0)]);
        assert_eq!(taps, vec![Tap::Single, Tap::Double]);
    }

    #[test]
    fn a_chord_or_a_slow_press_is_no_tap() {
        use Input::*;
        assert!(feed(&[(Down, 0.0), (Other, 50.0), (Up, 80.0)]).is_empty());
        assert!(feed(&[(Down, 0.0), (Up, 500.0)]).is_empty());
        // A key between two taps breaks the double tap.
        let taps = feed(&[(Down, 0.0), (Up, 80.0), (Other, 100.0), (Down, 200.0), (Up, 260.0)]);
        assert_eq!(taps, vec![Tap::Single, Tap::Single]);
    }
}
