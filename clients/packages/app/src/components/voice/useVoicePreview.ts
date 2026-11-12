import { useCall, type VoiceChoice } from "@comma/core-client";
import { useCallback, useEffect, useRef, useState } from "react";

// Settings › Voice's sample of a call voice: the core asks the server for a few seconds of the voice speaking, and this
// plays it. The server keeps none: a sample is kept on this device, each voice's apart (by voice and language, in the
// window's Cache Storage where it has one, and in memory while the page is open) and played from there after, the
// next page and the next launch too, without asking again.

/** The device's kept samples: one response per sample, under a made-up URL of its key. */
const DEVICE_CACHE = "comma-voice-samples-v1";
const deviceUrl = (cacheKey: string) =>
  `https://voice-samples.invalid/${encodeURIComponent(cacheKey)}`;

async function deviceCache(): Promise<Cache | undefined> {
  try {
    return typeof caches === "undefined" ? undefined : await caches.open(DEVICE_CACHE);
  } catch {
    return undefined;
  }
}

async function keptOnDevice(cacheKey: string): Promise<Blob | undefined> {
  const response = await (await deviceCache())?.match(deviceUrl(cacheKey));
  return response ? response.blob() : undefined;
}

/** Best effort: a sample not kept is asked for again next time. */
async function keepOnDevice(cacheKey: string, blob: Blob): Promise<void> {
  try {
    await (
      await deviceCache()
    )?.put(
      deviceUrl(cacheKey),
      new Response(blob, { headers: { "content-type": blob.type } })
    );
  } catch {
    // Kept in memory for this page only.
  }
}

export type VoicePreviewPhase = "loading" | "playing";

export function useVoicePreview(workspace: string | undefined, language: string) {
  const call = useCall();
  const [phase, setPhase] = useState<VoicePreviewPhase>();
  const [failed, setFailed] = useState(false);
  const samples = useRef(new Map<string, string>());
  const audio = useRef<HTMLAudioElement | null>(null);
  /** Each press's number: a sample that arrives after a newer press or a stop is not played. */
  const generation = useRef(0);

  const stop = useCallback(() => {
    generation.current += 1;
    audio.current?.pause();
    audio.current = null;
    setPhase(undefined);
  }, []);

  useEffect(() => {
    const kept = samples.current;
    return () => {
      generation.current += 1;
      audio.current?.pause();
      audio.current = null;
      for (const url of kept.values()) URL.revokeObjectURL(url);
      kept.clear();
    };
  }, []);

  const play = useCallback(
    async (voice: VoiceChoice | null, key: string) => {
      if (!workspace) return;
      stop();
      const mine = generation.current;
      setFailed(false);
      const cacheKey = `${key}\n${language}`;
      let url = samples.current.get(cacheKey);
      if (!url) {
        setPhase("loading");
        try {
          let blob = await keptOnDevice(cacheKey).catch(() => undefined);
          if (!blob) {
            const sample = await call("voice.preview", { workspace, voice, language });
            const bytes = Uint8Array.from(atob(sample.audio), (c) => c.charCodeAt(0));
            blob = new Blob([bytes], { type: sample.contentType });
            await keepOnDevice(cacheKey, blob);
          }
          url = URL.createObjectURL(blob);
          samples.current.set(cacheKey, url);
        } catch {
          if (generation.current === mine) {
            setPhase(undefined);
            setFailed(true);
          }
          return;
        }
      }
      if (generation.current !== mine) return;
      const element = new Audio(url);
      audio.current = element;
      const ended = () => {
        if (audio.current === element) stop();
      };
      element.addEventListener("ended", ended);
      element.addEventListener("error", ended);
      setPhase("playing");
      try {
        await element.play();
      } catch {
        ended();
      }
    },
    [call, language, stop, workspace]
  );

  return { phase, failed, play, stop };
}
