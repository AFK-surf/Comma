// WASAPI may deliver several 20 ms packets together. Preserve their order across pulls;
// discard old sound only when transport has fallen more than 300 ms behind.
use std::collections::VecDeque;
const MAX_PACKETS: usize = 15;
pub struct AudioQueue<T>(VecDeque<T>);
impl<T> AudioQueue<T> {
    pub fn new() -> Self { Self(VecDeque::new()) }
    pub fn push(&mut self, packet: T) {
        if self.0.len() == MAX_PACKETS { self.0.pop_front(); }
        self.0.push_back(packet);
    }
    pub fn pop(&mut self) -> Option<T> { self.0.pop_front() }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_capture_burst_loses_no_packets_between_pulls() {
        let mut queue = AudioQueue::new();
        for timestamp in [0, 20, 40] { queue.push(timestamp); }
        assert_eq!(queue.pop(), Some(0));
        queue.push(60);
        for timestamp in [20, 40, 60] { assert_eq!(queue.pop(), Some(timestamp)); }
        assert_eq!(queue.pop(), None);
    }
    #[test]
    fn slow_transport_keeps_only_a_bounded_recent_window() {
        let mut queue = AudioQueue::new();
        for timestamp in 0..100 { queue.push(timestamp); }
        for timestamp in 85..100 { assert_eq!(queue.pop(), Some(timestamp)); }
        assert_eq!(queue.pop(), None);
    }
}
