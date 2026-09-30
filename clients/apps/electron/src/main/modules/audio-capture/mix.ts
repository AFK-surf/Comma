import { readFile } from "node:fs/promises";

const WAV_HEADER_BYTES = 44;

export interface MonoPcm {
  sampleRate: number;
  samples: Float32Array;
}

/**
 * Reads a 16-bit PCM WAVE file written by `WavSink` (mono; a stereo file is
 * averaged down). Only the canonical 44-byte header layout is accepted.
 */
export async function readWavPcm(path: string): Promise<MonoPcm> {
  const bytes = await readFile(path);
  if (bytes.length < WAV_HEADER_BYTES || bytes.toString("ascii", 0, 4) !== "RIFF") {
    throw new Error(`${path} is not a RIFF WAVE file.`);
  }
  const channels = bytes.readUInt16LE(22);
  const sampleRate = bytes.readUInt32LE(24);
  const bitsPerSample = bytes.readUInt16LE(34);
  if (bitsPerSample !== 16 || channels < 1) {
    throw new Error(`${path} is not 16-bit PCM.`);
  }
  const declared = bytes.readUInt32LE(40);
  const available = bytes.length - WAV_HEADER_BYTES;
  const dataBytes =
    Math.min(declared, available) - (Math.min(declared, available) % (2 * channels));
  const frames = dataBytes / (2 * channels);
  const samples = new Float32Array(frames);
  for (let frame = 0; frame < frames; frame += 1) {
    let sum = 0;
    for (let channel = 0; channel < channels; channel += 1) {
      sum += bytes.readInt16LE(WAV_HEADER_BYTES + (frame * channels + channel) * 2);
    }
    samples[frame] = sum / channels / 0x8000;
  }
  return { sampleRate, samples };
}

/**
 * Averages two mono tracks sample by sample. Averaging rather than summing
 * keeps two already-hot signals from clipping; the shorter track is padded
 * with silence. Both tracks must share a sample rate.
 */
export function mixMono(first: MonoPcm, second: MonoPcm): MonoPcm {
  if (first.sampleRate !== second.sampleRate) {
    throw new Error(
      `Cannot mix ${first.sampleRate} Hz with ${second.sampleRate} Hz without resampling.`
    );
  }
  const length = Math.max(first.samples.length, second.samples.length);
  const mixed = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    const a = i < first.samples.length ? (first.samples[i] ?? 0) : 0;
    const b = i < second.samples.length ? (second.samples[i] ?? 0) : 0;
    mixed[i] = (a + b) / 2;
  }
  return { sampleRate: first.sampleRate, samples: mixed };
}
