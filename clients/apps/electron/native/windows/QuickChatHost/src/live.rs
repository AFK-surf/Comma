//! Live dictation (CommaWeb.DictationSocket on the server): this process opens the socket with a ticket from Main,
//! sends the microphone's 16 kHz PCM up and passes the server's words down. One run at a time, on a thread of its own;
//! until the socket opens, at most `QUEUE_FRAMES` frames wait (about 8 s of audio).

use std::net::TcpStream;
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::time::Duration;

use serde::Deserialize;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

const QUEUE_FRAMES: usize = 64;

/// What the server says (messages.ts's LiveEvent), and `Unavailable` when there is no live dictation now.
#[derive(Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LiveEvent {
    Partial { segment: u32, text: String },
    Final { segment: u32, text: String },
    Done,
    #[serde(skip)]
    Unavailable,
}

pub enum Up {
    Pcm(Vec<u8>),
    End,
    Cancel,
}

/// A run's channel: PCM, the end, or its cancel go up through it, from before its socket opens (they wait).
#[derive(Clone)]
pub struct Run {
    up: Sender<Up>,
}

/// The other end of a run, until its ticket comes and its socket opens.
pub struct Pending {
    down: Receiver<Up>,
}

impl Run {
    pub fn new() -> (Self, Pending) {
        let (up, down) = std::sync::mpsc::channel();
        (Self { up }, Pending { down })
    }

    pub fn pcm(&self, samples: &[i16]) {
        let bytes = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
        let _ = self.up.send(Up::Pcm(bytes));
    }

    pub fn end(&self) {
        let _ = self.up.send(Up::End);
    }

    pub fn cancel(&self) {
        let _ = self.up.send(Up::Cancel);
    }
}

impl Pending {
    /// Opens the socket at `url` with `ticket` on a thread; each event goes to `emit`.
    pub fn start(self, url: String, ticket: String, emit: impl Fn(LiveEvent) + Send + 'static) {
        std::thread::spawn(move || {
            if let Err(error) = run(&url, &ticket, self.down, &emit) {
                eprintln!("Live dictation ended: {error}");
                emit(LiveEvent::Unavailable);
            }
        });
    }
}

fn run(url: &str, ticket: &str, up: Receiver<Up>, emit: &dyn Fn(LiveEvent)) -> Result<(), String> {
    let address = format!("{url}?ticket={}", encode(ticket));
    let (mut socket, _) = tungstenite::connect(address).map_err(|e| e.to_string())?;
    set_read_timeout(&mut socket, Duration::from_millis(15));
    // What waited while the socket opened: its first `QUEUE_FRAMES` frames go up, the rest are dropped.
    let mut backlog = Some(0usize);
    let mut done = false;
    loop {
        loop {
            match up.try_recv() {
                Ok(Up::Pcm(bytes)) => {
                    if let Some(count) = backlog.as_mut() {
                        *count += 1;
                        if *count > QUEUE_FRAMES {
                            continue;
                        }
                    }
                    socket.send(Message::Binary(bytes.into())).map_err(|e| e.to_string())?;
                }
                Ok(Up::End) => socket.send(Message::Text(r#"{"type":"end"}"#.into())).map_err(|e| e.to_string())?,
                Ok(Up::Cancel) | Err(TryRecvError::Disconnected) => {
                    let _ = socket.close(None);
                    return Ok(());
                }
                Err(TryRecvError::Empty) => {
                    backlog = None;
                    break;
                }
            }
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                if let Ok(event) = serde_json::from_str::<LiveEvent>(&text) {
                    if event == LiveEvent::Done {
                        done = true;
                    }
                    emit(event);
                }
            }
            Ok(Message::Close(frame)) => {
                if done {
                    return Ok(());
                }
                return Err(format!("closed with {:?}", frame.map(|f| u16::from(f.code))));
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(tungstenite::Error::ConnectionClosed) if done => return Ok(()),
            Err(e) => return Err(e.to_string()),
        }
    }
}

fn set_read_timeout(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, timeout: Duration) {
    let stream: &TcpStream = match socket.get_ref() {
        MaybeTlsStream::Plain(stream) => stream,
        MaybeTlsStream::NativeTls(stream) => stream.get_ref(),
        _ => return,
    };
    let _ = stream.set_read_timeout(Some(timeout));
}

/// A ticket is URL-safe base64 already; anything else is percent-encoded.
fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_servers_frames_parse() {
        let partial: LiveEvent = serde_json::from_str(r#"{"type":"partial","segment":0,"text":"帮我"}"#).unwrap();
        assert_eq!(partial, LiveEvent::Partial { segment: 0, text: "帮我".into() });
        assert_eq!(serde_json::from_str::<LiveEvent>(r#"{"type":"done"}"#).unwrap(), LiveEvent::Done);
        assert_eq!(encode("a+b/c="), "a%2Bb%2Fc%3D");
    }
}
