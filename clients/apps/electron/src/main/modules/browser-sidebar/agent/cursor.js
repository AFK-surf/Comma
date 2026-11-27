// The agent's presence in an in-app browser tab: while the agent works, a
// glowing edge around the page and its cursor (Computer Use's,
// CUShared/Resources/OverlayCursor.png, brand blue #1040F2, drawn smaller),
// which glides to where it acts. The edge is the page's own: a fine bright
// line with a soft glow in the brand blue's steps, which swells and thins as
// it goes round, where Computer Use's border (CUShared/ColorfulBorder) is a
// wide noisy halo of many colours.
// Both are drawn in a closed shadow root over the page. The driver
// (./index.ts) evaluates this file in the "comma-agent" isolated world.
// Website scripts cannot reach it; it takes no pointer events and is
// aria-hidden, so it changes neither hit testing nor the agent's snapshots.
// It is built with DOM calls only: a page's CSP or Trusted Types policy
// blocks inline markup and data: images, not these.
(() => {
  // The driver calls `__commaAgentCursor.moveTo(...)` in this world.
  const NAME = "__commaAgentCursor";
  const C = globalThis[NAME] || (globalThis[NAME] = {});
  if (C.moveTo) return true;

  const SVG = "http://www.w3.org/2000/svg";
  // OverlayCursor.png traced on its 101-unit canvas: a blue arrow with
  // rounded corners in a white rim, drawn by stroking one outline twice,
  // with the tip at (17, 13). Computer Use renders it at 28 points over a
  // whole screen; in a page it is 22 px, near the size of the system arrow.
  const PATH = "M23.5 17.4L77.5 37.5L50.5 44.5L43.5 71.5Z";
  const SIZE = 22;
  const UNIT = SIZE / 101;
  const TIP_X = 17 * UNIT;
  const TIP_Y = 13 * UNIT;
  const IDLE_MS = 3000;
  const ENTER_MS = 600;
  // The edge has two layers. Each is a colour wheel that turns behind a mask,
  // and the mask says how much of the wheel shows by distance from the
  // viewport's edge: all of it for `line` px, then a glow that starts at
  // `peak` and eases to nothing at `reach` px (`power` says how soon it
  // thins), so the glow has no inner border. No layer is blurred: the wheels
  // are smooth.
  // Its colours are the brand blue's steps (theme.css `--color-brand-50` to
  // `-600`, written out: a page has none of the app's tokens), blended in
  // OKLCH from one step to the next. The edge is one hue: only its lightness
  // goes round.
  const BRAND = {
    50: "#B8DDFF",
    100: "#8CBFFF",
    200: "#619EFF",
    300: "#3B7CFF",
    400: "#205BFF",
    500: "#1040F2",
    600: "#092FC0",
  };
  const wheelColors = (stops) =>
    `in oklch, ${stops.map(([step, at, alpha = "FF"]) => `${BRAND[step]}${alpha} ${at}%`).join(", ")}`;
  // The rim: a fine bright line at the very edge and a short glow inside it.
  // The steps go up to a highlight and down again twice, a long climb to the
  // lightest step and a shorter one to a middle step.
  const RIM_COLORS = wheelColors([
    [600, 0],
    [500, 6],
    [400, 12],
    [300, 18],
    [200, 23],
    [100, 27],
    [50, 30],
    [100, 34],
    [200, 39],
    [300, 45],
    [400, 50],
    [500, 56],
    [400, 62],
    [300, 67],
    [200, 72],
    [300, 78],
    [400, 85],
    [500, 93],
    [600, 100],
  ]);
  const RIM_GLOW = { line: 2, peak: 0.7, reach: 40, power: 2.6 };
  // The bloom: a wide faint glow in two lobes of unequal length, a light one
  // and a deeper one, clear between them. It turns the other way, so the glow
  // swells and thins along the edge and the two layers' steps meet
  // differently each time round.
  const BLOOM_COLORS = wheelColors([
    [200, 0, "00"],
    [200, 10],
    [100, 22],
    [100, 34, "00"],
    [400, 50, "00"],
    [400, 60],
    [300, 70],
    [300, 80, "00"],
    [200, 100, "00"],
  ]);
  const BLOOM_GLOW = { line: 0, peak: 1, reach: 120, power: 2.8 };
  // The bloom arrives strong and settles: one saturated hue is heavy on a
  // white page, so neither is its full strength.
  const BLOOM_ARRIVE = 0.9;
  const BLOOM_REST = 0.55;
  let host;
  let edge;
  let bloom;
  let spin = [];
  let edgeTimer;
  let body;
  let arrow;
  let x;
  let y;
  let docked = false;

  // at: where the cursor was on the tab's previous document (Main keeps it).
  function ensure(at) {
    if (host && host.isConnected) return;
    host = document.createElement("comma-agent-cursor");
    host.setAttribute("aria-hidden", "true");
    const hostStyle = host.style;
    for (const [name, value] of [
      ["all", "initial"],
      ["position", "fixed"],
      ["inset", "0"],
      ["overflow", "hidden"],
      ["z-index", "2147483647"],
      ["pointer-events", "none"],
    ]) {
      hostStyle.setProperty(name, value, "important");
    }
    const root = host.attachShadow({ mode: "closed" });
    spin = [];
    edge = buildEdge();
    root.append(edge);
    body = document.createElement("div");
    Object.assign(body.style, {
      position: "absolute",
      left: "0",
      top: "0",
      width: SIZE + "px",
      height: SIZE + "px",
      opacity: "0",
      transition: "opacity 200ms ease",
      willChange: "transform",
    });
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 101 101");
    svg.setAttribute("width", String(SIZE));
    svg.setAttribute("height", String(SIZE));
    svg.style.overflow = "visible";
    // The sprite's shadow: 6 units of blur, 5 down. It is lighter than the
    // sprite's 55%, which smudges an arrow this small.
    svg.style.filter = `drop-shadow(0 ${5 * UNIT}px ${12 * UNIT}px rgba(0, 0, 0, 0.4))`;
    // The rim reaches 9 units past the outline, the blue 4.
    for (const [color, width] of [
      ["#FFFFFF", 18],
      ["#1040F2", 8],
    ]) {
      const path = document.createElementNS(SVG, "path");
      path.setAttribute("d", PATH);
      path.setAttribute("fill", color);
      path.setAttribute("stroke", color);
      path.setAttribute("stroke-width", String(width));
      path.setAttribute("stroke-linejoin", "round");
      svg.append(path);
    }
    arrow = svg;
    arrow.style.transformOrigin = `${TIP_X}px ${TIP_Y}px`;
    arrow.style.transition = "transform 90ms ease-out";
    body.append(svg);
    root.append(body);
    document.documentElement.append(host);
    // A new document keeps the cursor where it was on the tab's previous
    // one. The tab's first starts it where Computer Use docks it, the
    // bottom-left corner, and activate brings it in from there.
    if (x === undefined) {
      if (at) {
        x = Math.min(Math.max(at.x, 0), innerWidth);
        y = Math.min(Math.max(at.y, 0), innerHeight);
      } else {
        x = 24;
        y = innerHeight - 24;
        docked = true;
      }
    }
    place(x, y, 0);
  }

  // The edge: the rim and, under it, the bloom.
  function buildEdge() {
    const frame = document.createElement("div");
    Object.assign(frame.style, {
      position: "absolute",
      inset: "0",
      overflow: "hidden",
      opacity: "0",
      transition: "opacity 300ms ease",
    });
    // The bloom goes round at an uneven pace: it never stops and never runs
    // steady, so it does not read as a wheel.
    const uneven = "cubic-bezier(0.4, 0.1, 0.6, 0.9)";
    bloom = edgeLayer(BLOOM_COLORS, BLOOM_GLOW, 19000, [
      { turn: 0, easing: uneven },
      { turn: -0.42, easing: uneven },
      { turn: -1 },
    ]);
    bloom.style.opacity = String(BLOOM_REST);
    frame.append(
      bloom,
      edgeLayer(RIM_COLORS, RIM_GLOW, 12000, [{ turn: 0 }, { turn: 1 }])
    );
    for (const animation of spin) animation.pause();
    return frame;
  }

  // One layer of the edge: a colour wheel as wide as the viewport's
  // diagonal, which turns about the viewport's centre once in `ms`, behind a
  // mask that lets it show only near the four sides.
  function edgeLayer(colors, { line, peak, reach, power }, ms, turns) {
    // The glow's curve in short straight runs, too short to show as bands.
    const STEPS = 16;
    const glow = Array.from({ length: STEPS + 1 }, (_, step) => {
      const share = peak * (1 - step / STEPS) ** power;
      const px = line + ((reach - line) * step) / STEPS;
      return `rgb(0 0 0 / ${share.toFixed(3)}) ${px.toFixed(1)}px`;
    });
    const stops = [`#000 ${line}px`, ...glow].join(", ");
    const layer = document.createElement("div");
    Object.assign(layer.style, {
      position: "absolute",
      inset: "0",
      overflow: "hidden",
      mask: ["bottom", "top", "right", "left"]
        .map((side) => `linear-gradient(to ${side}, ${stops})`)
        .join(", "),
    });
    const wheel = document.createElement("div");
    Object.assign(wheel.style, {
      position: "absolute",
      left: "50%",
      top: "50%",
      width: "142vmax",
      height: "142vmax",
      background: `conic-gradient(${colors})`,
    });
    layer.append(wheel);
    spin.push(
      wheel.animate(
        turns.map(({ turn, easing }) => ({
          transform: `translate(-50%, -50%) rotate(${turn}turn)`,
          ...(easing ? { easing } : {}),
        })),
        { duration: ms, iterations: Infinity }
      )
    );
    return layer;
  }

  function place(toX, toY, ms) {
    body.style.transition = `opacity 200ms ease, transform ${ms}ms cubic-bezier(0.4, 0, 0.2, 1)`;
    body.style.transform = `translate(${toX - TIP_X}px, ${toY - TIP_Y}px)`;
    x = toX;
    y = toY;
  }

  // Shows the edge and the cursor, where it last pointed, while the agent
  // works, for holdMs (the length of a command, then a short tail after
  // it); they fade once nothing renews it. A docked cursor glides from the
  // corner to the page's centre as the agent starts. Returns where the
  // cursor goes.
  C.activate = (holdMs = IDLE_MS, at = null) => {
    ensure(at);
    // An edge that comes in arrives strong and settles.
    if (edge.style.opacity !== "1") {
      bloom.animate([{ opacity: BLOOM_ARRIVE }, { opacity: BLOOM_REST }], {
        duration: 1400,
        easing: "ease-in-out",
      });
    }
    edge.style.opacity = "1";
    body.style.opacity = "1";
    if (docked) {
      docked = false;
      void body.getBoundingClientRect();
      place(innerWidth / 2, innerHeight / 2, ENTER_MS);
    }
    // With less motion asked, the edge keeps its colours and does not turn.
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    for (const animation of spin) {
      if (reduced) animation.pause();
      else animation.play();
    }
    clearTimeout(edgeTimer);
    edgeTimer = setTimeout(() => {
      edge.style.opacity = "0";
      body.style.opacity = "0";
      // Nothing turns behind a hidden edge.
      edgeTimer = setTimeout(() => {
        for (const animation of spin) animation.pause();
      }, 400);
    }, holdMs);
    return { x, y };
  };

  // Moves the cursor to a point in viewport coordinates. With animate, it
  // glides there and the returned promise settles with the point once it
  // has arrived; a tab nobody sees moves it at once. press adds the
  // click's dip.
  C.moveTo = (toX, toY, { animate = true, press = false } = {}, at = null) => {
    ensure(at);
    docked = false;
    const distance = Math.hypot(toX - x, toY - y);
    const ms = animate ? Math.round(Math.min(380, Math.max(120, distance * 0.6))) : 0;
    // Let the browser take the start position before the transition.
    void body.getBoundingClientRect();
    place(toX, toY, ms);
    return new Promise((resolve) => {
      setTimeout(
        () => {
          if (press && animate) {
            arrow.style.transform = "scale(0.82)";
            setTimeout(() => {
              arrow.style.transform = "scale(1)";
            }, 110);
          }
          resolve({ x: toX, y: toY });
        },
        ms + (animate ? 40 : 0)
      );
    });
  };

  // Points at an element's centre, when it is on screen.
  C.moveToElement = (el, options, at) => {
    // An element in a frame has its own viewport: no cursor for it.
    if (el.ownerDocument !== document) return Promise.resolve(false);
    const rect = el.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    if (!rect.width || cx < 0 || cy < 0 || cx > innerWidth || cy > innerHeight) {
      return Promise.resolve(false);
    }
    return C.moveTo(cx, cy, options, at);
  };

  return true;
})();
