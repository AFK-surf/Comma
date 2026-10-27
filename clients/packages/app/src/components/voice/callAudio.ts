// The desktop voice call's speaker and microphone (the core's voice-call.ts runs the call; Main holds its socket). The
// Router's 24 kHz PCM16 frames are scheduled back to back; a mark is answered once every frame before it has played,
// and a clear (the caller spoke over it) drops what is still queued and answers every waiting mark, as the phones do.
// The microphone goes to Main in 20 ms frames of the same format, with the browser's echo cancellation; muted, the
// frames keep coming as silence, as the phones send them, since the server ends a call whose audio stops.

const SAMPLE_RATE = 24_000;
/** 20 ms of audio. */
const FRAME_SAMPLES = 480;

export interface CallAudioOut {
  microphone(pcm: Uint8Array): void;
  played(name: string): void;
}

export class CallAudio {
  readonly #out: CallAudioOut;
  #context: AudioContext | null = null;
  #stream: MediaStream | null = null;
  #capture: ScriptProcessorNode | null = null;
  #pending = new Int16Array(FRAME_SAMPLES);
  #pendingLength = 0;
  #muted = false;
  /** When the queued audio ends, on the context's clock. */
  #playEnd = 0;
  #sources = new Set<AudioBufferSourceNode>();
  /** Marks waiting for their audio, oldest first: each with the source that ends just before it (none: nothing). */
  #marks: { name: string; after: AudioBufferSourceNode | null }[] = [];
  #last: AudioBufferSourceNode | null = null;
  #stopped = false;

  constructor(out: CallAudioOut) {
    this.#out = out;
  }

  async start(): Promise<void> {
    const context = new AudioContext({
      sampleRate: SAMPLE_RATE,
      latencyHint: "interactive",
    });
    this.#context = context;
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    if (this.#stopped) {
      for (const track of stream.getTracks()) track.stop();
      return;
    }
    this.#stream = stream;
    const input = context.createMediaStreamSource(stream);
    // A script processor needs no module of its own to load; 1024 samples is about 43 ms at 24 kHz.
    const capture = context.createScriptProcessor(1024, 1, 1);
    capture.addEventListener("audioprocess", (event) =>
      this.#captured(event.inputBuffer.getChannelData(0))
    );
    input.connect(capture);
    // A processor runs only while it leads somewhere; its output is silence.
    capture.connect(context.destination);
    this.#capture = capture;
  }

  setMuted(muted: boolean): void {
    this.#muted = muted;
    this.#pendingLength = 0;
  }

  play(pcm: Uint8Array): void {
    const context = this.#context;
    if (!context || pcm.byteLength < 2) return;
    const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength);
    const samples = pcm.byteLength >> 1;
    const buffer = context.createBuffer(1, samples, SAMPLE_RATE);
    const channel = buffer.getChannelData(0);
    for (let i = 0; i < samples; i++) channel[i] = view.getInt16(i * 2, true) / 0x8000;
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    const at = Math.max(context.currentTime, this.#playEnd);
    source.start(at);
    this.#playEnd = at + buffer.duration;
    this.#sources.add(source);
    this.#last = source;
    source.addEventListener(
      "ended",
      () => {
        // A cleared source is no longer this call's.
        if (!this.#sources.delete(source)) return;
        if (this.#last === source) this.#last = null;
        this.#answerThrough(source);
      },
      { once: true }
    );
  }

  mark(name: string): void {
    const after = this.#last;
    if (!after) {
      // Nothing is waiting to play: it has all been heard.
      if (this.#marks.length === 0) this.#out.played(name);
      else this.#marks.push({ name, after: null });
      return;
    }
    this.#marks.push({ name, after });
  }

  /** The caller spoke over the Router: what is queued is dropped, and every mark counts as played. */
  clear(): void {
    const sources = [...this.#sources];
    this.#sources.clear();
    this.#last = null;
    for (const source of sources) source.stop();
    this.#playEnd = 0;
    for (const mark of this.#marks.splice(0)) this.#out.played(mark.name);
  }

  stop(): void {
    this.#stopped = true;
    this.clear();
    this.#marks = [];
    this.#capture?.disconnect();
    this.#capture = null;
    for (const track of this.#stream?.getTracks() ?? []) track.stop();
    this.#stream = null;
    void this.#context?.close();
    this.#context = null;
  }

  /** Answers, in order, the marks up to the last waiting for `source`, and those after it with nothing to wait for. */
  #answerThrough(source: AudioBufferSourceNode): void {
    const index = this.#marks.findLastIndex((mark) => mark.after === source);
    if (index < 0) return;
    for (const mark of this.#marks.splice(0, index + 1)) this.#out.played(mark.name);
    while (this.#marks[0]?.after === null) this.#out.played(this.#marks.shift()!.name);
  }

  #captured(samples: Float32Array): void {
    if (this.#stopped) return;
    const muted = this.#muted;
    for (const sample of samples) {
      const clamped = muted ? 0 : Math.max(-1, Math.min(1, sample));
      this.#pending[this.#pendingLength++] =
        clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
      if (this.#pendingLength === FRAME_SAMPLES) {
        const frame = new Uint8Array(FRAME_SAMPLES * 2);
        const view = new DataView(frame.buffer);
        for (let i = 0; i < FRAME_SAMPLES; i++)
          view.setInt16(i * 2, this.#pending[i]!, true);
        this.#pendingLength = 0;
        this.#out.microphone(frame);
      }
    }
  }
}
