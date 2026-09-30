import { Link, createFileRoute } from "@tanstack/react-router";
import { Download, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { StatePanel } from "../components/Status";
import { m } from "../paraglide/messages.js";
import { useLocale } from "../i18n/locale";

type ViewerSearch = { src: string; title: string; kind: "json" | "log" };
export const Route = createFileRoute("/viewer")({
  validateSearch: (search: Record<string, unknown>): ViewerSearch => ({
    src:
      typeof search.src === "string" && search.src.startsWith("/api/results/downloads/")
        ? search.src
        : "",
    title: typeof search.title === "string" ? search.title : m.viewer_default_title(),
    kind: search.kind === "log" ? "log" : "json",
  }),
  component: ViewerPage,
});

function ViewerPage() {
  useLocale();
  const { src, title, kind } = Route.useSearch();
  const [state, setState] = useState<{
    status: "loading" | "ready" | "error";
    text?: string;
    truncated?: boolean;
    error?: string;
  }>({ status: "loading" });
  const [query, setQuery] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    void readBounded(src, controller.signal).then(
      (result) => setState({ status: "ready", ...result }),
      (error) =>
        setState({
          status: "error",
          error: error instanceof Error ? error.message : String(error),
        })
    );
    return () => controller.abort();
  }, [src]);
  const lines = useMemo(
    () =>
      (state.text ?? "")
        .split("\n")
        .filter((line) => !query || line.toLowerCase().includes(query.toLowerCase())),
    [state.text, query]
  );
  return (
    <main className="page-shell">
      <header className="page-heading">
        <div>
          <Link className="back-link" search={{ page: 1 }} to="/">
            {m.viewer_back()}
          </Link>
          <h1>{title}</h1>
          <p>{m.viewer_preview_note()}</p>
        </div>
        <a className="secondary-button" href={src}>
          <Download size={14} /> {m.viewer_raw_file()}
        </a>
      </header>
      {state.status === "loading" ? (
        <StatePanel title={m.viewer_loading()} detail={m.viewer_loading_detail()} />
      ) : state.status === "error" ? (
        <StatePanel
          title={m.viewer_unavailable()}
          detail={state.error ?? m.viewer_unknown_error()}
        />
      ) : (
        <section className="content-section">
          <div className="section-heading controls-heading">
            <div>
              <h2>{kind === "log" ? m.viewer_logs() : m.viewer_json()}</h2>
              {state.truncated && <p>{m.viewer_truncated()}</p>}
            </div>
            <label className="field compact-field">
              <span>{m.common_filter()}</span>
              <div className="input-action">
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder={m.viewer_search_placeholder()}
                />
                <span className="icon-button">
                  <Search size={14} />
                </span>
              </div>
            </label>
          </div>
          <pre className="data-preview">
            {kind === "json" ? prettyJson(state.text ?? "") : lines.join("\n")}
          </pre>
        </section>
      )}
    </main>
  );
}

async function readBounded(src: string, signal: AbortSignal) {
  if (!src) throw new Error(m.viewer_invalid_url());
  const response = await fetch(src, { signal });
  if (!response.ok || !response.body)
    throw new Error(m.viewer_request_failed({ status: response.status }));
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  const limit = 2 * 1024 * 1024;
  let truncated = false;
  while (bytes < limit) {
    const { value, done } = await reader.read();
    if (done) break;
    const remaining = limit - bytes;
    chunks.push(value.byteLength > remaining ? value.slice(0, remaining) : value);
    bytes += Math.min(value.byteLength, remaining);
    if (value.byteLength > remaining || bytes >= limit) {
      truncated = true;
      await reader.cancel();
      break;
    }
  }
  const combined = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { text: new TextDecoder().decode(combined), truncated };
}

function prettyJson(text: string) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}
