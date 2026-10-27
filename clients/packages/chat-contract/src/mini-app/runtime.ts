/* eslint-disable unicorn/require-post-message-target-origin -- MessagePort messages do not accept an origin. */
/// <reference lib="dom" />
import { createFrameComma } from "@comma/miniapp-sdk/frame";
import { miniAppCapabilityOps } from "@comma/miniapp-sdk";

export type {
  MiniAppCapability,
  MiniAppErrorCode,
  MiniAppFile,
  MiniAppFramePortMessage,
  MiniAppHelloMessage,
  MiniAppHostPortMessage,
  MiniAppInit,
  MiniAppInitMessage,
  MiniAppOp,
  MiniAppOpRequirement,
  MiniAppOpTable,
  MiniAppReadyMessage,
  MiniAppResultMessage,
  MiniAppStorageOpTable,
  MiniAppStorageScope,
  MiniAppTheme,
  MiniAppViewer,
} from "@comma/miniapp-sdk";
export {
  miniAppCapabilities,
  miniAppCapabilityOps,
  miniAppOpRequirement,
} from "@comma/miniapp-sdk";

/**
 * The Comma app runtime: one fixed document that runs a Comma app in a
 * sandboxed frame with an opaque origin. The document holds no app content.
 * The host sends the app bundle over the port that `comma-app:init`
 * transfers (design AFK-surf/Cue#4070 §7).
 */
export const miniAppRuntimeUrl = "comma-app://runtime/";
export const miniAppWebRuntimePath = "/app-runtime/";

/** Runtime-side limits (design §5.4, §7.2). */
export const miniAppRuntimeLimits = {
  maxFiles: 2000,
  maxIndexBytes: 8 * 1024 * 1024,
  maxBundleBytes: 25 * 1024 * 1024,
  startTimeoutMs: 10_000,
} as const;

type Limits = typeof miniAppRuntimeLimits;
type CreateFrameComma = typeof createFrameComma;

/**
 * The runtime's only script. Its source text goes into the document, so it
 * must stay self-contained.
 *
 * Module imports between bundle files: an app must build to one module script
 * (the template uses vite-plugin-singlefile). A module that runs from a
 * `blob:` URL has no base URL for `./chunk.js`, and the CSP admits no inline
 * import map, so a relative import fails and the start fails with an error
 * that says so. The runtime does not rewrite JavaScript: a rewrite needs a
 * full parser to be correct, and a wrong rewrite breaks apps silently. A
 * file the app loads on demand stays possible: `import(comma.asset("x.js"))`.
 */
function runtimeBootstrap(
  createComma: CreateFrameComma,
  capabilityOps: Record<string, readonly string[]>,
  limits: Limits
) {
  let initialized = false;
  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== parent) return;
    const data = event.data as { type?: unknown; init?: unknown } | null;
    if (!initialized && data?.type === "comma-app:hello") {
      parent.postMessage({ type: "comma-app:ready" }, "*");
      return;
    }
    if (initialized || data?.type !== "comma-app:init" || event.ports.length !== 1)
      return;
    initialized = true;
    start(event.ports[0]!, data.init as Record<string, unknown>);
  });

  function start(port: MessagePort, init: Record<string, unknown>) {
    const send = (message: unknown, transfer: Transferable[] = []) =>
      port.postMessage(message, transfer);
    const pending = new Map<
      number,
      { resolve(value: unknown): void; reject(error: unknown): void }
    >();
    let serial = 0;
    let stopped = false;
    let loading = false;
    let started = false;
    let startTimer: number | undefined;
    let setTheme:
      | ((change: { theme: "light" | "dark"; tokens: Record<string, string> }) => void)
      | undefined;

    // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized frame bootstrap.
    const applyTheme = (theme: unknown, tokens: unknown) => {
      const root = document.documentElement;
      const scheme = theme === "dark" ? "dark" : "light";
      root.dataset.theme = scheme;
      root.style.colorScheme = scheme;
      if (!tokens || typeof tokens !== "object") return {};
      const accepted: Record<string, string> = {};
      for (const [name, value] of Object.entries(tokens as Record<string, unknown>)) {
        if (
          /^--[a-zA-Z0-9-]{1,64}$/.test(name) &&
          typeof value === "string" &&
          value.length < 300 &&
          !/[;{}]|url\(/i.test(value)
        ) {
          root.style.setProperty(name, value);
          accepted[name] = value;
        }
      }
      return accepted;
    };

    const stop = (reason: string, report: boolean) => {
      if (stopped) return;
      stopped = true;
      if (startTimer !== undefined) clearTimeout(startTimer);
      for (const call of pending.values())
        call.reject({ code: "unavailable", message: "The app stopped." });
      pending.clear();
      document.head.replaceChildren();
      document.body.replaceChildren();
      if (report) send({ type: "error", reason });
    };

    const call = (op: string, args: unknown) =>
      new Promise<unknown>((resolve, reject) => {
        if (stopped) {
          reject({ code: "unavailable", message: "The app stopped." });
          return;
        }
        const id = ++serial;
        try {
          send({ type: "call", id, op, args });
        } catch {
          reject({
            code: "invalid",
            message: `The arguments of ${op} cannot be sent.`,
          });
          return;
        }
        pending.set(id, { resolve, reject });
      });

    const fail = (reason: string) => stop(reason, true);

    const load = (files: unknown) => {
      if (!Array.isArray(files)) throw Error("The bundle is invalid.");
      if (files.length > limits.maxFiles)
        throw Error(`The bundle has more than ${limits.maxFiles} files.`);
      const urls = new Map<string, string>();
      const bytes = new Map<string, ArrayBuffer>();
      let total = 0;
      for (const file of files as {
        path?: unknown;
        mime?: unknown;
        data?: unknown;
      }[]) {
        if (
          !file ||
          typeof file.path !== "string" ||
          typeof file.mime !== "string" ||
          !(file.data instanceof ArrayBuffer) ||
          file.path.length > 512 ||
          file.path.split("/").some((part) => !part || part === "." || part === "..")
        )
          throw Error("The bundle has an invalid file.");
        total += file.data.byteLength;
        if (total > limits.maxBundleBytes)
          throw Error("The bundle is larger than 25 MiB.");
        bytes.set(file.path, file.data);
        urls.set(
          file.path,
          URL.createObjectURL(new Blob([file.data], { type: file.mime.slice(0, 200) }))
        );
      }
      const index = bytes.get("index.html");
      if (!index) throw Error("The bundle has no index.html.");
      if (index.byteLength > limits.maxIndexBytes)
        throw Error("index.html is larger than 8 MiB.");

      // A path of the bundle for `reference`, resolved from the file `from`.
      // eslint-disable-next-line unicorn/consistent-function-scoping -- This helper must travel with the serialized frame bootstrap.
      const resolve = (from: string, reference: string) => {
        const trimmed = reference.trim();
        if (
          !trimmed ||
          /^[a-z][a-z0-9+.-]*:/i.test(trimmed) ||
          trimmed.startsWith("//") ||
          trimmed.startsWith("#")
        )
          return undefined;
        let path = trimmed.replace(/[?#].*$/, "");
        try {
          path = decodeURIComponent(path);
        } catch {
          return undefined;
        }
        const parts = path.startsWith("/") ? [] : from.split("/").slice(0, -1);
        for (const part of path.split("/")) {
          if (!part || part === ".") continue;
          if (part === "..") parts.pop();
          else parts.push(part);
        }
        return parts.join("/");
      };
      const rewrite = (from: string, reference: string) => {
        const path = resolve(from, reference);
        return path === undefined ? reference : (urls.get(path) ?? reference);
      };
      const rewriteCss = (from: string, css: string) =>
        css.replaceAll(
          /url\(\s*(['"]?)([^'")]*)\1\s*\)/gi,
          (match, quote: string, reference: string) => {
            const next = rewrite(from, reference);
            return next === reference ? match : `url(${quote}${next}${quote})`;
          }
        );
      const decoder = new TextDecoder();

      const sdk = createComma({
        init: init as never,
        call,
        assetUrl: (path) => urls.get(path),
        capabilityOps,
      });
      setTheme = sdk.setTheme;
      Object.defineProperty(window, "comma", {
        value: sdk.comma,
        writable: false,
        configurable: false,
        enumerable: true,
      });

      // Parsed markup is inert: nothing in it runs or loads.
      const parsed = new DOMParser().parseFromString(
        decoder.decode(index),
        "text/html"
      );
      parsed
        .querySelectorAll("base, meta[http-equiv], iframe, frame, object, embed")
        .forEach((node) => node.remove());
      for (const link of parsed.querySelectorAll("link")) {
        const rel = (link.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
        const path = resolve("index.html", link.getAttribute("href") ?? "");
        if (rel.includes("stylesheet") && path !== undefined && bytes.has(path)) {
          const style = parsed.createElement("style");
          style.textContent = rewriteCss(path, decoder.decode(bytes.get(path)));
          link.replaceWith(style);
        } else link.remove();
      }
      for (const style of parsed.querySelectorAll("style"))
        style.textContent = rewriteCss("index.html", style.textContent ?? "");
      for (const element of parsed.querySelectorAll("[style]"))
        element.setAttribute(
          "style",
          rewriteCss("index.html", element.getAttribute("style")!)
        );
      for (const element of parsed.querySelectorAll(
        "img[src], source[src], video[src], audio[src], track[src], input[src]"
      ))
        element.setAttribute(
          "src",
          rewrite("index.html", element.getAttribute("src")!)
        );
      for (const element of parsed.querySelectorAll("video[poster]"))
        element.setAttribute(
          "poster",
          rewrite("index.html", element.getAttribute("poster")!)
        );
      for (const element of parsed.querySelectorAll("img[srcset], source[srcset]"))
        element.setAttribute(
          "srcset",
          element
            .getAttribute("srcset")!
            .split(",")
            .map((candidate) => {
              const [reference = "", ...rest] = candidate.trim().split(/\s+/);
              return [rewrite("index.html", reference), ...rest].join(" ");
            })
            .join(", ")
        );

      // Scripts run from blob: URLs, in document order.
      const scripts: { module: boolean; url: string }[] = [];
      for (const script of parsed.querySelectorAll("script")) {
        const type = (script.getAttribute("type") ?? "").trim().toLowerCase();
        const module = type === "module";
        const classic = ["", "text/javascript", "application/javascript"].includes(
          type
        );
        if (type === "importmap")
          throw Error(
            "Import maps are not supported. Build the app to one module script."
          );
        if (!module && !classic) continue; // A data block stays as it is.
        const source = script.getAttribute("src");
        if (source !== null) {
          const path = resolve("index.html", source);
          const url = path === undefined ? undefined : urls.get(path);
          if (!url) throw Error(`The script ${source} is not in the bundle.`);
          scripts.push({ module, url });
        } else {
          const url = URL.createObjectURL(
            new Blob([script.textContent ?? ""], { type: "text/javascript" })
          );
          scripts.push({ module, url });
        }
        script.remove();
      }

      for (const name of ["lang", "dir", "class"]) {
        const value = parsed.documentElement.getAttribute(name);
        if (value !== null) document.documentElement.setAttribute(name, value);
      }
      for (const attribute of parsed.body.attributes)
        if (!attribute.name.startsWith("on"))
          document.body.setAttribute(attribute.name, attribute.value);
      for (const node of Array.from(parsed.head.childNodes))
        if (node instanceof HTMLStyleElement)
          document.head.append(document.adoptNode(node));
      document.body.append(
        ...[...parsed.body.childNodes].map((node) => document.adoptNode(node))
      );

      // An error while the app's scripts start fails the start.
      const startError = (event: ErrorEvent) => {
        if (!started && !stopped) fail(`The app failed to start: ${event.message}`);
      };
      window.addEventListener("error", startError);
      let remaining = scripts.length;
      const settle = () => {
        if (stopped || started || --remaining > 0) return;
        started = true;
        window.removeEventListener("error", startError);
        if (startTimer !== undefined) clearTimeout(startTimer);
        send({ type: "started" });
      };
      if (!scripts.length) {
        remaining = 1;
        settle();
        return;
      }
      for (const entry of scripts) {
        const element = document.createElement("script");
        if (entry.module) element.type = "module";
        element.async = false;
        element.addEventListener("load", settle);
        element.addEventListener("error", () =>
          fail("The app failed to start: a script did not load.")
        );
        element.src = entry.url;
        document.body.append(element);
      }
    };

    port.addEventListener("message", (event: MessageEvent) => {
      const message = event.data as Record<string, unknown> | null;
      if (!message || typeof message !== "object") return;
      switch (message.type) {
        case "ping":
          if (!stopped) send({ type: "pong", n: message.n });
          return;
        case "result": {
          const entry = pending.get(message.id as number);
          if (!entry) return;
          pending.delete(message.id as number);
          if (message.ok === true) entry.resolve(message.value);
          else
            entry.reject(
              message.error ?? { code: "failed", message: "The call failed." }
            );
          return;
        }
        case "theme": {
          const tokens = applyTheme(message.theme, message.tokens);
          setTheme?.({ theme: message.theme === "dark" ? "dark" : "light", tokens });
          return;
        }
        case "stop":
          stop(typeof message.reason === "string" ? message.reason : "stopped", false);
          return;
        case "files":
          if (loading || stopped) return;
          loading = true;
          startTimer = window.setTimeout(
            () => fail("The app did not start within 10 seconds."),
            limits.startTimeoutMs
          );
          try {
            load(message.files);
          } catch (error) {
            fail(error instanceof Error ? error.message : "The app could not load.");
          }
          return;
        default:
      }
    });
    port.start();
    applyTheme(init?.theme, init?.tokens);
  }

  parent.postMessage({ type: "comma-app:ready" }, "*");
}

// --- SHA-256, for the script's CSP hash -----------------------------------------

const sha256Constants = Uint32Array.from(
  "428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5 d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174 e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da 983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967 27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85 a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070 19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3 748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2"
    .split(" ")
    .map((word) => Number.parseInt(word, 16))
);

const rotate = (value: number, bits: number) =>
  (value >>> bits) | (value << (32 - bits));

/** The base64 SHA-256 digest of `text` (UTF-8), synchronously. */
export function sha256Base64(text: string) {
  const message = new TextEncoder().encode(text);
  const length = Math.ceil((message.length + 9) / 64) * 64;
  const padded = new Uint8Array(length);
  padded.set(message);
  padded[message.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(length - 8, Math.floor((message.length * 8) / 2 ** 32));
  view.setUint32(length - 4, (message.length * 8) >>> 0);
  const hash = Uint32Array.from([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
    0x5be0cd19,
  ]);
  const words = new Uint32Array(64);
  for (let offset = 0; offset < length; offset += 64) {
    for (let i = 0; i < 16; i++) words[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 64; i++) {
      const a = words[i - 15]!;
      const b = words[i - 2]!;
      words[i] =
        (words[i - 16]! +
          (rotate(a, 7) ^ rotate(a, 18) ^ (a >>> 3)) +
          words[i - 7]! +
          (rotate(b, 17) ^ rotate(b, 19) ^ (b >>> 10))) >>>
        0;
    }
    const v = [...hash];
    for (let i = 0; i < 64; i++) {
      const [a, b, c, d, e, f, g, h] = v as [
        number,
        number,
        number,
        number,
        number,
        number,
        number,
        number,
      ];
      const t1 =
        h +
        (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) +
        ((e & f) ^ (~e & g)) +
        sha256Constants[i]! +
        words[i]!;
      const t2 =
        (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      v.splice(0, 8, (t1 + t2) >>> 0, a, b, c, (d + t1) >>> 0, e, f, g);
    }
    // A Uint32Array keeps each sum modulo 2^32.
    v.forEach((value, i) => {
      hash[i] = hash[i]! + value;
    });
  }
  let binary = "";
  for (const word of hash)
    binary += String.fromCharCode(
      word >>> 24,
      (word >>> 16) & 255,
      (word >>> 8) & 255,
      word & 255
    );
  return btoa(binary);
}

// --- The document and its policy -------------------------------------------------

// An inline script ends at the first `</script`, wherever it is.
const runtimeScript =
  `(()=>{const __name=(fn)=>fn;(${runtimeBootstrap.toString()})(${createFrameComma.toString()},${JSON.stringify(miniAppCapabilityOps)},${JSON.stringify(miniAppRuntimeLimits)})})()`.replaceAll(
    "</script",
    "<\\/script"
  );

const runtimeDocument = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body><script>${runtimeScript}</script></body></html>`;

/**
 * The sandbox of the runtime frame, as its attribute and in its policy. `allow-forms` lets a form fire its `submit`
 * event for the app's handler; `form-action 'none'` still stops every submission from leaving the frame.
 */
export const miniAppFrameSandbox = "allow-scripts allow-forms";

/** The runtime's Content Security Policy (design §7.1), sent as a header on both hosts. */
export const miniAppRuntimeCsp = `sandbox ${miniAppFrameSandbox}; default-src 'none'; script-src 'sha256-${sha256Base64(runtimeScript)}' blob:; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data:; media-src blob: data:; worker-src blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`;

/** The runtime document. It holds no app content. */
export function miniAppRuntimeDocument() {
  return runtimeDocument;
}
