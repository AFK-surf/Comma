import { open, rm, type FileHandle } from "node:fs/promises";

/** Canonical PCM WAVE header; the two size fields are patched in on finalize. */
const WAV_HEADER_BYTES = 44;
const WAV_PCM_FORMAT_TAG = 1;
const WAV_BITS_PER_SAMPLE = 16;
const WAV_BYTES_PER_SAMPLE = WAV_BITS_PER_SAMPLE / 8;
const WAV_RIFF_SIZE_OFFSET = 4;
const WAV_DATA_SIZE_OFFSET = 40;

/**
 * Speech recognition consumes mono 16 kHz; capture hardware hands us 48 kHz
 * stereo. Normalizing here keeps the stored artifact a sixth of the size and
 * removes a conversion step from every downstream consumer.
 */
export const WAV_TARGET_SAMPLE_RATE = 16_000;

export interface WavSinkOpenInput {
  /** Interleaved channel count of the incoming frames. */
  channels: number;
  path: string;
  /** Sample rate of the incoming frames, before any decimation. */
  sampleRate: number;
}

export interface WavSinkSummary {
  byteLength: number;
  durationMs: number;
  /** Channel count actually written — always 1, the mono downmix. */
  channels: number;
  /** Sample rate actually written, which may differ from the capture rate. */
  sampleRate: number;
}

/**
 * Main-owned incremental WAVE writer.
 *
 * Native capture callbacks arrive faster than the filesystem drains, so writes
 * are appended to a single serialized tail and the caller never awaits inside
 * the capture callback. A write failure is retained and rethrown by `finalize`,
 * because the callback has no other place to surface it.
 */
export class WavSink {
  readonly #channels: number;
  readonly #decimation: number;
  readonly #handle: FileHandle;
  readonly #path: string;
  readonly #sampleRate: number;
  #carrySum = 0;
  #carryCount = 0;
  #closed = false;
  #dataBytes = 0;
  #failure: Error | undefined;
  #tail: Promise<void> = Promise.resolve();

  private constructor(input: {
    channels: number;
    decimation: number;
    handle: FileHandle;
    path: string;
    sampleRate: number;
  }) {
    this.#channels = input.channels;
    this.#decimation = input.decimation;
    this.#handle = input.handle;
    this.#path = input.path;
    this.#sampleRate = input.sampleRate;
  }

  static async open({ channels, path, sampleRate }: WavSinkOpenInput) {
    if (!Number.isInteger(channels) || channels < 1 || channels > 8) {
      throw new Error(`Unsupported capture channel count: ${channels}.`);
    }
    if (!Number.isInteger(sampleRate) || sampleRate < 8_000 || sampleRate > 192_000) {
      throw new Error(`Unsupported capture sample rate: ${sampleRate}.`);
    }

    const handle = await open(path, "w");
    const sink = new WavSink({
      channels,
      // Averaging every N input samples is a crude but real low-pass; an
      // integer ratio is the only case where it is honest, so any other rate
      // is stored at its native rate rather than aliased down.
      decimation:
        sampleRate % WAV_TARGET_SAMPLE_RATE === 0
          ? sampleRate / WAV_TARGET_SAMPLE_RATE
          : 1,
      handle,
      path,
      sampleRate,
    });
    await handle.write(sink.#header(), 0, WAV_HEADER_BYTES, 0);
    return sink;
  }

  get byteLength() {
    return this.#dataBytes;
  }

  get outputSampleRate() {
    return this.#sampleRate / this.#decimation;
  }

  get durationMs() {
    return Math.round(
      (this.#dataBytes / WAV_BYTES_PER_SAMPLE / this.outputSampleRate) * 1_000
    );
  }

  /**
   * Queues one interleaved capture chunk. Never rejects: the capture callback
   * cannot handle a rejection, so failures are retained for `finalize`.
   */
  write(frames: Float32Array) {
    if (this.#closed || this.#failure) return;
    const chunk = this.#encode(frames);
    if (chunk.byteLength === 0) return;
    this.#dataBytes += chunk.byteLength;
    const offset = WAV_HEADER_BYTES + this.#dataBytes - chunk.byteLength;
    this.#tail = this.#tail.then(async () => {
      if (this.#failure) return;
      try {
        await this.#handle.write(chunk, 0, chunk.byteLength, offset);
      } catch (error) {
        this.#failure = error instanceof Error ? error : new Error(String(error));
      }
    });
  }

  /** Drains queued writes, patches the RIFF sizes, and closes the file. */
  async finalize(): Promise<WavSinkSummary> {
    if (this.#closed) throw new Error("This WAVE sink is already closed.");
    this.#closed = true;
    this.#flushCarry();
    await this.#tail;
    if (this.#failure) {
      await this.#handle.close();
      await rm(this.#path, { force: true });
      throw this.#failure;
    }

    const riffSize = Buffer.allocUnsafe(4);
    riffSize.writeUInt32LE(WAV_HEADER_BYTES - 8 + this.#dataBytes, 0);
    await this.#handle.write(riffSize, 0, 4, WAV_RIFF_SIZE_OFFSET);
    const dataSize = Buffer.allocUnsafe(4);
    dataSize.writeUInt32LE(this.#dataBytes, 0);
    await this.#handle.write(dataSize, 0, 4, WAV_DATA_SIZE_OFFSET);
    await this.#handle.sync();
    await this.#handle.close();

    return {
      byteLength: this.#dataBytes,
      channels: 1,
      durationMs: this.durationMs,
      sampleRate: this.outputSampleRate,
    };
  }

  /** Closes and removes the partial file. Safe to call after `finalize`. */
  async discard() {
    if (!this.#closed) {
      this.#closed = true;
      await this.#tail.catch(() => undefined);
      await this.#handle.close().catch(() => undefined);
    }
    await rm(this.#path, { force: true });
  }

  #header() {
    const header = Buffer.alloc(WAV_HEADER_BYTES);
    const sampleRate = this.outputSampleRate;
    const byteRate = sampleRate * WAV_BYTES_PER_SAMPLE;
    header.write("RIFF", 0, "ascii");
    header.writeUInt32LE(WAV_HEADER_BYTES - 8, WAV_RIFF_SIZE_OFFSET);
    header.write("WAVE", 8, "ascii");
    header.write("fmt ", 12, "ascii");
    header.writeUInt32LE(16, 16);
    header.writeUInt16LE(WAV_PCM_FORMAT_TAG, 20);
    header.writeUInt16LE(1, 22);
    header.writeUInt32LE(sampleRate, 24);
    header.writeUInt32LE(byteRate, 28);
    header.writeUInt16LE(WAV_BYTES_PER_SAMPLE, 32);
    header.writeUInt16LE(WAV_BITS_PER_SAMPLE, 34);
    header.write("data", 36, "ascii");
    header.writeUInt32LE(0, WAV_DATA_SIZE_OFFSET);
    return header;
  }

  /** Downmixes to mono, decimates, and converts to little-endian 16-bit PCM. */
  #encode(frames: Float32Array) {
    const channels = this.#channels;
    const frameCount = Math.floor(frames.length / channels);
    const out = Buffer.allocUnsafe(
      Math.ceil((frameCount + this.#carryCount) / this.#decimation) *
        WAV_BYTES_PER_SAMPLE
    );
    let written = 0;

    for (let frame = 0; frame < frameCount; frame += 1) {
      let sum = 0;
      for (let channel = 0; channel < channels; channel += 1) {
        sum += frames[frame * channels + channel] ?? 0;
      }
      this.#carrySum += sum / channels;
      this.#carryCount += 1;
      if (this.#carryCount === this.#decimation) {
        out.writeInt16LE(toPcm16(this.#carrySum / this.#decimation), written);
        written += WAV_BYTES_PER_SAMPLE;
        this.#carrySum = 0;
        this.#carryCount = 0;
      }
    }

    return out.subarray(0, written);
  }

  /** Emits the partially accumulated sample so the tail is not truncated. */
  #flushCarry() {
    if (this.#carryCount === 0) return;
    const sample = Buffer.allocUnsafe(WAV_BYTES_PER_SAMPLE);
    sample.writeInt16LE(toPcm16(this.#carrySum / this.#carryCount), 0);
    const offset = WAV_HEADER_BYTES + this.#dataBytes;
    this.#dataBytes += WAV_BYTES_PER_SAMPLE;
    this.#carrySum = 0;
    this.#carryCount = 0;
    this.#tail = this.#tail.then(async () => {
      if (this.#failure) return;
      try {
        await this.#handle.write(sample, 0, sample.byteLength, offset);
      } catch (error) {
        this.#failure = error instanceof Error ? error : new Error(String(error));
      }
    });
  }
}

/** Root-mean-square of one interleaved chunk, clamped to the 0..1 meter range. */
export function frameLevel(frames: Float32Array) {
  if (frames.length === 0) return 0;
  let total = 0;
  for (let index = 0; index < frames.length; index += 1) {
    const sample = frames[index] ?? 0;
    total += sample * sample;
  }
  return Math.min(1, Math.sqrt(total / frames.length));
}

function toPcm16(sample: number) {
  const clamped = Math.max(-1, Math.min(1, sample));
  return Math.round(clamped * (clamped < 0 ? 0x8000 : 0x7fff));
}
