import { useCommaMessages } from "@comma/i18n/react";
import {
  CheckIcon,
  CircleCheckIcon,
  Cursor1Icon,
  GithubBrandIcon,
  GoogleBrandIcon,
  LoaderIcon,
  NotionBrandIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { useState, type CSSProperties } from "react";
import { WorkerModelMark } from "../chat/thread/activity/WorkerModelMark";
import { CommaProductMark } from "../CommaProductMark";

export type WebIntroScene = "router" | "apps" | "mac";

const scenes: readonly WebIntroScene[] = ["router", "apps", "mac"];

/** A scene that has played, and the edge it first arrived from. */
type SeenScene = { scene: WebIntroScene; arrive?: "before" | "after" };

/**
 * Where one of the card's stacked layers stands against the tip on show: the
 * tips already passed wait at the start edge and the ones ahead at the end
 * edge, so a step forward leaves towards the start and arrives from the end,
 * and a step back runs the other way.
 */
export function layerPosition(layer: number, current: number) {
  if (layer === current) return "current";
  return layer < current ? "before" : "after";
}

/**
 * The illustration at the top of the web intro card: each tip's feature, drawn
 * as the product shows it, in miniature. The pieces are local copies of the
 * product's chat, task, plugin, recorder and composer surfaces, without their
 * behaviour or data. Each scene plays once, the first time its tip opens, and
 * then rests in its finished state, which is all reduced motion shows; nothing
 * loops. A scene stays mounted once it has played, so a quick run of Next or a
 * step back hands the stage over from wherever each scene stands. A scene
 * shown for the first time arrives from the edge its tip comes from, and its
 * first piece starts with the swap while the outgoing scene fades, so the stage
 * does not empty between tips.
 */
export function WebIntroMotion({ scene }: { scene: WebIntroScene }) {
  const [shown, setShown] = useState(scene);
  const [seen, setSeen] = useState<readonly SeenScene[]>([{ scene }]);
  const current = scenes.indexOf(scene);
  if (shown !== scene) {
    setShown(scene);
    if (!seen.some((entry) => entry.scene === scene)) {
      setSeen([
        ...seen,
        { scene, arrive: scenes.indexOf(shown) < current ? "after" : "before" },
      ]);
    }
  }
  return (
    <div aria-hidden className="comma-web-intro-stage">
      {scenes.map((item, itemIndex) => {
        const entry = seen.find((candidate) => candidate.scene === item);
        return entry ? (
          <div
            className="comma-web-intro-layer comma-web-intro-canvas"
            data-arrive={entry.arrive}
            data-position={layerPosition(itemIndex, current)}
            key={item}
          >
            {item === "router" ? <RouterScene /> : null}
            {item === "apps" ? <AppsScene /> : null}
            {item === "mac" ? <MacScene /> : null}
          </div>
        ) : null;
      })}
    </div>
  );
}

/** The `animation-delay` of one step of a scene, in seconds. */
const at = (seconds: number): CSSProperties =>
  ({ "--comma-web-intro-at": `${seconds}s` }) as CSSProperties;

/** Three Workers, each shown by its model's maker, and when each finishes. */
const workers = [
  { id: "web-intro-worker-1", vendor: "anthropic", done: 2.1 },
  { id: "web-intro-worker-2", vendor: "openai", done: 2.5 },
  { id: "web-intro-worker-3", vendor: "google", done: 2.3 },
] as const;

/** When the Router hands the Tasks out, and when the Workers start on them. */
const dispatch = 0.85;
const work = 1.3;

/**
 * Home's chat, and what happens behind it: the user's request goes to the
 * Router, which thinks, then hands it out as Tasks along the links to Workers.
 * The Workers run them side by side, each result travels back up its link,
 * and once all are back the Router answers.
 */
function RouterScene() {
  return (
    <>
      <div className="comma-web-intro-bubble comma-web-intro-rise" style={at(0.05)}>
        <span />
      </div>
      <div className="comma-web-intro-team">
        <div
          className="comma-web-intro-router-row comma-web-intro-rise"
          style={at(0.3)}
        >
          <span className="comma-web-intro-router">
            <CommaProductMark viewBox="2 2 16 16" />
          </span>
          <span className="comma-web-intro-router-status">
            <span className="comma-web-intro-thinking" style={at(2.85)}>
              <span className="comma-web-intro-shimmer" style={at(0.35)} />
            </span>
            <span
              className="comma-web-intro-reply comma-web-intro-fade"
              style={at(2.85)}
            />
          </span>
        </div>
        <svg className="comma-web-intro-links" viewBox="0 0 24 82">
          {workers.map((worker, index) => {
            // Each link runs from the Router's mark to just under its Task's
            // edge. Its stroke starts at the branch above, so no stretch of the
            // trunk is painted twice; the pulses ride the whole way.
            const y = 29 + index * 22;
            const link = `M8 ${index === 0 ? 18 : y - 27}V${y - 5}Q8 ${y} 13 ${y}H25`;
            const out = `M8 18V${y - 5}Q8 ${y} 13 ${y}H25`;
            const back = `M25 ${y}H13Q8 ${y} 8 ${y - 5}V18`;
            // A 6px bead on every link, whatever its length (trunk, corner,
            // branch), as a share of the normalised path.
            const bead = 6 / (y - 23 + 7.65 + 12);
            const pulse = {
              "--comma-web-intro-bead": bead.toFixed(4),
              "--comma-web-intro-hide": (bead + 0.01).toFixed(4),
            } as CSSProperties;
            return (
              <g key={worker.id}>
                <path
                  className="comma-web-intro-link"
                  d={link}
                  pathLength={1}
                  style={at(dispatch + index * 0.08)}
                />
                <path
                  className="comma-web-intro-pulse"
                  d={out}
                  pathLength={1}
                  style={{ ...at(dispatch + index * 0.08), ...pulse }}
                />
                <path
                  className="comma-web-intro-pulse"
                  d={back}
                  pathLength={1}
                  style={{ ...at(worker.done), ...pulse }}
                />
              </g>
            );
          })}
        </svg>
        <div className="comma-web-intro-tasks">
          {workers.map((worker, index) => (
            <div
              className="comma-web-intro-task comma-web-intro-dispatch"
              key={worker.id}
              style={at(dispatch + 0.2 + index * 0.08)}
            >
              <WorkerModelMark
                className="comma-web-intro-worker"
                vendor={worker.vendor}
              />
              <span className="comma-web-intro-line">
                <span
                  className="comma-web-intro-work"
                  style={
                    {
                      ...at(work),
                      "--comma-web-intro-for": `${worker.done - work}s`,
                    } as CSSProperties
                  }
                />
              </span>
              <span className="comma-web-intro-swap">
                <span className="comma-web-intro-pending" style={at(worker.done)}>
                  <LoaderIcon className="animate-spin" />
                </span>
                <span className="comma-web-intro-done" style={at(worker.done)}>
                  <CircleCheckIcon />
                </span>
              </span>
            </div>
          ))}
        </div>
      </div>
    </>
  );
}

const apps = [
  { icon: GoogleBrandIcon, name: "Google" },
  { icon: GithubBrandIcon, name: "GitHub" },
  { icon: NotionBrandIcon, name: "Notion" },
] as const;

/**
 * The apps list, in the plugin row's geometry: each app's Connect presses,
 * spins while it signs in, then gives way to the product's Connected state,
 * one app after another.
 */
function AppsScene() {
  const m = useCommaMessages();
  return (
    <div
      className="comma-web-intro-panel comma-web-intro-apps comma-web-intro-fade"
      style={at(0)}
    >
      {apps.map(({ icon: Icon, name }, index) => (
        <div
          className="comma-web-intro-app comma-web-intro-rise"
          key={name}
          style={at(index * 0.06)}
        >
          <span className="comma-web-intro-artwork">
            <Icon />
          </span>
          <span className="comma-web-intro-app-copy">
            <span className="comma-web-intro-app-name">{name}</span>
            <span className="comma-web-intro-line" />
          </span>
          {/* Its layers read this step's start from here. */}
          <span className="comma-web-intro-connect" style={at(0.8 + index * 0.9)}>
            <span className="comma-web-intro-connect-button">
              <span className="comma-web-intro-swap">
                <span className="comma-web-intro-idle">
                  {m.onboarding_apps_connect()}
                </span>
                <span className="comma-web-intro-pending">
                  <LoaderIcon className="animate-spin" />
                </span>
              </span>
            </span>
            <span className="comma-web-intro-done">
              <CheckIcon />
              {m.onboarding_apps_connected()}
            </span>
          </span>
        </div>
      ))}
    </div>
  );
}

/**
 * What the Mac app adds: the meeting recorder, computer use clicking in a
 * window, and voice input in the composer. The three surfaces arrive together,
 * then act in turn.
 */
function MacScene() {
  return (
    <>
      <div className="comma-web-intro-recorder comma-web-intro-rise" style={at(0)}>
        <span className="comma-web-intro-rec" />
        <span className="comma-web-intro-line" />
        <span className="comma-web-intro-timer">00:12</span>
        <span className="comma-web-intro-stop" />
      </div>
      <div className="comma-web-intro-window comma-web-intro-rise" style={at(0.03)}>
        <span className="comma-web-intro-traffic">
          <span />
          <span />
          <span />
        </span>
        <span className="comma-web-intro-line" />
        <span className="comma-web-intro-line" />
        <span className="comma-web-intro-target" />
        <Cursor1Icon className="comma-web-intro-cursor" />
      </div>
      <div className="comma-web-intro-composer comma-web-intro-rise" style={at(0.06)}>
        <span className="comma-web-intro-wave">
          {Array.from({ length: 18 }, (_, index) => (
            <span key={index} />
          ))}
        </span>
        <span className="comma-web-intro-timer">0:08</span>
        <XIcon className="comma-web-intro-control" />
        <CheckIcon className="comma-web-intro-control" />
      </div>
    </>
  );
}
