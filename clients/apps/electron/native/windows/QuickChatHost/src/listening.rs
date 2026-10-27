//! One Quick Chat's listening, as the overlay page's Listening. The words come from the server's live dictation
//! (live.rs): the microphone's 16 kHz PCM goes up as it is heard, and each segment's words come back as they are
//! recognized, settling when its speaker pauses, in the language spoken.
//!
//! Without live dictation (no ticket, no recognizer on the server, a socket that fails) the microphone is recorded as
//! M4A clips (clip.rs), one per natural pause, at most `CLIP_SECONDS` each, and the server transcribes each one (Main's
//! `transcribe`). The words show clip by clip, in the order they were said; a clip that failed is asked once more when
//! the words are sent. Until live dictation answers, a clip records too, so that falling back loses nothing; it is
//! dropped once live words come.
//!
//! Bounds: at most two clips in transcription at once; a clip at most a minute. After `finish`, live dictation's last
//! words are waited for `LIVE_END_SECONDS` at most, and a clip's words `TRANSCRIPT_SECONDS`.
//!
//! The microphone's thread hears; everything else happens on the window's thread, which hands this what arrives
//! (`live`, `clip`, `clip_audio`, `transcript`) and calls `tick` each frame.
//!
//! For tests, `QUICK_CHAT_TEST_AUDIO` names a 16 kHz mono s16le file heard in place of the microphone, at its pace.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

use crate::audio::{decibels, voice_level, Microphone, SpeechPause, SAMPLE_RATE};
use crate::live::{LiveEvent, Pending, Run};
use crate::spoken::join_spoken;

/// How many samples go up at once (128 ms).
const FRAME_SAMPLES: usize = 2_048;
const CLIP_SECONDS: usize = 60;
const IN_FLIGHT: usize = 2;
/// The last segment's final words come from the server's transcription of its audio (at most about 9 s after it ends),
/// after the live recognizer's.
const LIVE_END_SECONDS: f64 = 12.0;
/// A clip's words are given up after this; Main answers every clip, but a restart drops the question.
const TRANSCRIPT_SECONDS: f64 = 20.0;

/// Live dictation: waiting for its first words, giving them, or not used (clips instead).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Live {
    Waiting = 0,
    On = 1,
    Off = 2,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Failure {
    MicrophoneDenied,
    SpeechUnavailable,
}

/// What the window's thread is told from the others.
pub trait Post: Send + Sync + 'static {
    /// A clip the microphone's thread closed at a pause.
    fn clip(&self, listening: usize, samples: Vec<i16>);
    /// A clip's M4A, base64, or None when it could not be made.
    fn clip_audio(&self, listening: usize, clip: usize, audio: Option<String>);
    fn failure(&self, listening: usize, failure: Failure);
}

/// What the microphone's thread shares with the window's.
struct Heard {
    level: AtomicU32,
    /// Speech was heard; and how many times it began (the silence limit starts over).
    spoke: AtomicBool,
    speech: AtomicU32,
    live: AtomicU8,
    finished: AtomicBool,
    recording: Mutex<Recording>,
}

/// The clip being recorded.
struct Recording {
    on: bool,
    samples: Vec<i16>,
    /// Speech in it.
    spoke: bool,
}

struct Clip {
    /// Its M4A, base64: None while it is made; Some(None) when it could not be.
    audio: Option<Option<String>>,
    /// The server's words, once answered: None when there were none.
    words: Option<Option<String>>,
    failed: bool,
    /// Its question to Main: id, when, and whether it waits for its turn.
    asked: Option<(String, f64, bool)>,
}

enum Source {
    Microphone(#[allow(dead_code)] Microphone),
    File(Arc<AtomicBool>),
}

impl Drop for Source {
    fn drop(&mut self) {
        if let Source::File(running) = self {
            running.store(false, Ordering::SeqCst);
        }
    }
}

pub struct Listening {
    pub id: usize,
    heard: Arc<Heard>,
    source: Option<Source>,
    post: Arc<dyn Post>,
    run: Run,
    pending_run: Option<Pending>,
    /// What the clips' words continue: the draft, or live dictation's words when it failed partway.
    base: String,
    segments: BTreeMap<u32, String>,
    clips: Vec<Clip>,
    live: Live,
    live_ending: Option<f64>,
    text: String,
    finished: bool,
    stopped: bool,
    sending: bool,
    retried: bool,
}

impl Listening {
    /// Starts hearing; the words continue `draft`.
    pub fn start(id: usize, draft: String, post: Arc<dyn Post>) -> Self {
        let (run, pending) = Run::new();
        let heard = Arc::new(Heard {
            level: AtomicU32::new(0),
            spoke: AtomicBool::new(false),
            speech: AtomicU32::new(0),
            live: AtomicU8::new(Live::Waiting as u8),
            finished: AtomicBool::new(false),
            recording: Mutex::new(Recording { on: true, samples: Vec::new(), spoke: false }),
        });
        let mut frame = Vec::with_capacity(FRAME_SAMPLES);
        let mut pause = SpeechPause::default();
        let (up, shared, poster) = (run.clone(), heard.clone(), post.clone());
        let on_samples = move |samples: &[i16]| {
            let db = decibels(samples);
            shared.level.store(voice_level(db).to_bits(), Ordering::Relaxed);
            let paused = pause.hear(db, samples.len() as f32 / SAMPLE_RATE as f32);
            let live = shared.live.load(Ordering::Relaxed);
            {
                let mut recording = shared.recording.lock().unwrap();
                if recording.on {
                    recording.samples.extend_from_slice(samples);
                }
                if pause.spoke && !recording.spoke {
                    recording.spoke = true;
                    shared.spoke.store(true, Ordering::Relaxed);
                    shared.speech.fetch_add(1, Ordering::Relaxed);
                }
                // A pause, or a minute of speech: this clip goes to the server and the next one starts at once. Live
                // dictation hears the pauses itself; while it is awaited, the clip keeps everything said.
                let long = recording.samples.len() >= CLIP_SECONDS * SAMPLE_RATE as usize;
                if live == Live::Off as u8 && recording.on && recording.spoke && (paused || long) {
                    let samples = std::mem::take(&mut recording.samples);
                    recording.spoke = false;
                    poster.clip(id, samples);
                }
            }
            if live != Live::Off as u8 && !shared.finished.load(Ordering::Relaxed) {
                for &sample in samples {
                    frame.push(sample);
                    if frame.len() == FRAME_SAMPLES {
                        up.pcm(&frame);
                        frame.clear();
                    }
                }
            }
        };
        let failing = post.clone();
        let source = match std::env::var("QUICK_CHAT_TEST_AUDIO") {
            Ok(path) => Source::File(play_file(path, on_samples)),
            Err(_) => Source::Microphone(Microphone::start(on_samples, move |error| {
                eprintln!("Quick Chat could not open the microphone: {error}");
                // Windows' privacy settings refuse with E_ACCESSDENIED.
                let denied = error.code().0 == 0x80070005u32 as i32;
                failing.failure(id, if denied { Failure::MicrophoneDenied } else { Failure::SpeechUnavailable });
            })),
        };
        Self {
            id,
            heard,
            source: Some(source),
            post,
            run,
            pending_run: Some(pending),
            base: draft.clone(),
            segments: BTreeMap::new(),
            clips: Vec::new(),
            live: Live::Waiting,
            live_ending: None,
            text: draft,
            finished: false,
            stopped: false,
            sending: false,
            retried: false,
        }
    }

    /// The ticket came: the socket opens, and what was heard meanwhile goes up first.
    pub fn connect(&mut self, url: String, ticket: String, emit: impl Fn(LiveEvent) + Send + 'static) {
        if let Some(pending) = self.pending_run.take() {
            pending.start(url, ticket, emit);
        }
    }

    /// The draft and every segment's or clip's words so far, in order.
    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn level(&self) -> f32 {
        f32::from_bits(self.heard.level.load(Ordering::Relaxed))
    }

    /// Speech was heard in this Quick Chat, though its words may still be on their way.
    pub fn heard(&self) -> bool {
        self.heard.spoke.load(Ordering::Relaxed)
    }

    /// How many times speech began.
    pub fn speech(&self) -> u32 {
        self.heard.speech.load(Ordering::Relaxed)
    }

    /// Words still on their way: live dictation's last, or clips being transcribed.
    pub fn pending(&self) -> bool {
        if self.live == Live::On {
            return self.live_ending.is_some();
        }
        self.clips.iter().any(|clip| clip.words.is_none())
    }

    /// After `finish`: live dictation has given its last words, or the last clip is closed (its words may still be
    /// on their way to the server). What the editor opened with is then what was said.
    pub fn heard_out(&self) -> bool {
        self.stopped || (self.finished && self.live_ending.is_none())
    }

    /// After `finish`: every word is in (or this stopped).
    pub fn settled(&self) -> bool {
        self.stopped || (self.finished && !self.pending())
    }

    fn set_live(&mut self, live: Live) {
        self.live = live;
        self.heard.live.store(live as u8, Ordering::Relaxed);
    }

    /// What the server said of live dictation.
    pub fn live(&mut self, event: LiveEvent) {
        if self.stopped || self.live == Live::Off {
            return;
        }
        match event {
            LiveEvent::Partial { segment, text } | LiveEvent::Final { segment, text } => {
                if self.live == Live::Waiting {
                    // Live words came: the clip recorded meanwhile is not needed.
                    self.set_live(Live::On);
                    let mut recording = self.heard.recording.lock().unwrap();
                    recording.on = false;
                    recording.samples.clear();
                }
                self.segments.insert(segment, text);
                self.settle();
            }
            LiveEvent::Done => {
                self.live_ending = None;
                self.settle();
            }
            LiveEvent::Unavailable => self.fall_back(),
        }
    }

    /// Live dictation stopped answering: clips from here on, continuing its words.
    fn fall_back(&mut self) {
        let was_on = self.live == Live::On;
        self.set_live(Live::Off);
        self.run.cancel();
        self.base = self.text.clone();
        self.segments.clear();
        self.live_ending = None;
        if was_on && !self.finished {
            *self.heard.recording.lock().unwrap() = Recording { on: true, samples: Vec::new(), spoke: false };
        }
        self.settle();
    }

    /// The microphone stops and the clip being said is kept; the words settle after. A send's (`for_send`) clips wait
    /// for their turn at the server, the last one too.
    pub fn finish(&mut self, for_send: bool, now: f64) {
        if for_send {
            self.sending = true;
        }
        if self.finished || self.stopped {
            return;
        }
        self.finished = true;
        self.heard.finished.store(true, Ordering::Relaxed);
        self.source = None;
        if self.live == Live::On {
            self.live_ending = Some(now + LIVE_END_SECONDS);
            self.run.end();
            return;
        }
        if self.live == Live::Waiting {
            self.set_live(Live::Off);
            self.run.cancel();
        }
        let recording = std::mem::replace(
            &mut *self.heard.recording.lock().unwrap(),
            Recording { on: false, samples: Vec::new(), spoke: false },
        );
        if recording.spoke && !recording.samples.is_empty() {
            self.add_clip(recording.samples);
        }
        self.settle();
    }

    /// After `finish`, for a send: clips that failed are asked once more, waiting for their turn.
    pub fn retry_for_send(&mut self, now: f64) {
        if self.retried {
            return;
        }
        self.retried = true;
        self.sending = true;
        for clip in &mut self.clips {
            if clip.failed {
                clip.failed = false;
                clip.words = None;
            }
        }
        self.run_clips(now);
    }

    /// Everything stops, the clips under way too; their words are not wanted.
    pub fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        self.heard.finished.store(true, Ordering::Relaxed);
        self.source = None;
        if self.live != Live::Off {
            self.run.cancel();
        }
    }

    /// A clip the microphone's thread closed.
    pub fn clip(&mut self, samples: Vec<i16>) {
        if !self.stopped && !samples.is_empty() {
            self.add_clip(samples);
        }
    }

    fn add_clip(&mut self, samples: Vec<i16>) {
        let index = self.clips.len();
        self.clips.push(Clip { audio: None, words: None, failed: false, asked: None });
        let (post, id) = (self.post.clone(), self.id);
        std::thread::spawn(move || {
            let audio = crate::clip::m4a(&samples)
                .map(|file| crate::clip::base64(&file))
                .map_err(|error| eprintln!("A Quick Chat clip could not be made: {error}"))
                .ok();
            post.clip_audio(id, index, audio);
        });
    }

    pub fn clip_audio(&mut self, index: usize, audio: Option<String>, now: f64) {
        if let Some(clip) = self.clips.get_mut(index) {
            clip.audio = Some(audio);
            self.run_clips(now);
        }
    }

    /// The server's words for a clip asked as `clip_id`; None when it could not transcribe it.
    pub fn transcript(&mut self, clip_id: &str, text: Option<String>, now: f64) -> bool {
        let Some(clip) = self.clips.iter_mut().find(|c| c.asked.as_ref().is_some_and(|(id, _, _)| id == clip_id)) else {
            return false;
        };
        let (_, _, wait_for_slot) = clip.asked.take().unwrap();
        let heard = text.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        if heard.is_none() {
            eprintln!("A Quick Chat clip has no words.");
        }
        // A clip of a pause that failed is asked again with the send; a send's own is final.
        clip.failed = heard.is_none() && !wait_for_slot;
        clip.words = Some(heard);
        self.settle();
        self.run_clips(now);
        true
    }

    /// A frame: what waited too long is given up.
    pub fn tick(&mut self, now: f64) {
        if self.live_ending.is_some_and(|deadline| now > deadline) {
            eprintln!("Quick Chat's live dictation did not settle its last words.");
            self.live_ending = None;
            self.settle();
        }
        let mut gave_up = false;
        for clip in &mut self.clips {
            if clip.asked.as_ref().is_some_and(|(_, asked, _)| now - asked > TRANSCRIPT_SECONDS) {
                let (_, _, wait_for_slot) = clip.asked.take().unwrap();
                clip.failed = !wait_for_slot;
                clip.words = Some(None);
                gave_up = true;
            }
        }
        if gave_up {
            self.settle();
            self.run_clips(now);
        }
    }

    /// Asks Main for the next clips' words, in order, up to `IN_FLIGHT` at once.
    fn run_clips(&mut self, now: f64) {
        if self.stopped {
            return;
        }
        let mut running = self.clips.iter().filter(|c| c.asked.is_some()).count();
        let mut changed = false;
        for clip in &mut self.clips {
            if running >= IN_FLIGHT {
                break;
            }
            if clip.words.is_some() || clip.asked.is_some() {
                continue;
            }
            match &clip.audio {
                None => continue,
                Some(None) => {
                    clip.words = Some(None);
                    clip.failed = !self.sending;
                    changed = true;
                }
                Some(Some(audio)) => {
                    let clip_id = crate::random_id();
                    crate::write(&serde_json::json!({
                        "type": "transcribe", "clipId": clip_id, "audio": audio, "waitForSlot": self.sending,
                    }));
                    clip.asked = Some((clip_id, now, self.sending));
                    running += 1;
                }
            }
        }
        if changed {
            self.settle();
        }
    }

    fn settle(&mut self) {
        let mut text = self.base.clone();
        for said in self.segments.values() {
            let said = said.trim();
            if !said.is_empty() {
                text = join_spoken(&text, said);
            }
        }
        for clip in &self.clips {
            if let Some(Some(words)) = &clip.words {
                text = join_spoken(&text, words);
            }
        }
        self.text = text;
    }
}

/// Plays a 16 kHz mono s16le file into `on_samples` at its pace, in 10 ms packets, as the microphone gives them.
fn play_file(path: String, mut on_samples: impl FnMut(&[i16]) + Send + 'static) -> Arc<AtomicBool> {
    let running = Arc::new(AtomicBool::new(true));
    let alive = running.clone();
    std::thread::spawn(move || {
        let Ok(bytes) = std::fs::read(&path) else { return };
        let samples: Vec<i16> = bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
        let packet = (SAMPLE_RATE / 100) as usize;
        let start = std::time::Instant::now();
        let silence = vec![0i16; packet];
        let mut index = 0;
        while alive.load(Ordering::SeqCst) {
            let due = start + std::time::Duration::from_millis(10 * index as u64);
            if let Some(wait) = due.checked_duration_since(std::time::Instant::now()) {
                std::thread::sleep(wait);
            }
            let from = index * packet;
            if from < samples.len() {
                on_samples(&samples[from..(from + packet).min(samples.len())]);
            } else {
                on_samples(&silence);
            }
            index += 1;
        }
    });
    running
}
