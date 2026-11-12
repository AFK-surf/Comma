// The agent's presence in an in-app browser tab, as Computer Use shows it:
// while the agent works, a glowing colourful edge around the page
// (CUShared/ColorfulBorder) and its cursor (CUShared/Resources/
// OverlayCursor.png, brand blue #1040F2), which glides to where it acts.
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
  // rounded corners in a white rim, drawn by stroking one outline twice.
  // Computer Use renders it at 28 points with the tip at (17, 13).
  const PATH = "M23.5 17.4L77.5 37.5L50.5 44.5L43.5 71.5Z";
  const SIZE = 28;
  const TIP_X = (17 / 101) * SIZE;
  const TIP_Y = (13 / 101) * SIZE;
  const IDLE_MS = 3000;
  const ENTER_MS = 600;
  // The Computer Use border's colours (ColorfulBorderView.shaderColors).
  const EDGE_COLORS = [
    "#EFB04C",
    "#E98056",
    "#EA4B6B",
    "#E661A5",
    "#DF8AE9",
    "#C0A0F5",
    "#64B5F5",
    "#7EC9EE",
  ];
  let host;
  let edge;
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
    // The sprite's shadow: 6 units of blur, 5 down, at 55%.
    svg.style.filter = "drop-shadow(0 1.4px 3.3px rgba(0, 0, 0, 0.55))";
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

  // The edge: a turning conic gradient in a ring at the viewport's edge,
  // blurred into a glow.
  function buildEdge() {
    const frame = document.createElement("div");
    Object.assign(frame.style, {
      position: "absolute",
      inset: "0",
      overflow: "hidden",
      opacity: "0",
      transition: "opacity 300ms ease",
    });
    const gradient = `conic-gradient(${[...EDGE_COLORS, EDGE_COLORS[0]].join(", ")})`;
    const ringMask = "linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0)";
    const layer = document.createElement("div");
    Object.assign(layer.style, {
      position: "absolute",
      inset: "0",
      filter: "blur(12px) saturate(1.8)",
    });
    const ring = document.createElement("div");
    Object.assign(ring.style, {
      position: "absolute",
      inset: "0",
      overflow: "hidden",
      boxSizing: "border-box",
      padding: "10px",
      mask: ringMask,
      webkitMask: ringMask,
      maskComposite: "exclude",
      webkitMaskComposite: "xor",
    });
    const turning = document.createElement("div");
    Object.assign(turning.style, {
      position: "absolute",
      left: "50%",
      top: "50%",
      width: "200vmax",
      height: "200vmax",
      background: gradient,
    });
    ring.append(turning);
    layer.append(ring);
    frame.append(layer);
    spin.push(
      turning.animate(
        [
          { transform: "translate(-50%, -50%) rotate(0turn)" },
          { transform: "translate(-50%, -50%) rotate(1turn)" },
        ],
        { duration: 4000, iterations: Infinity }
      )
    );
    // The glow breathes while the agent works.
    spin.push(
      layer.animate([{ opacity: 0.7 }, { opacity: 1 }, { opacity: 0.7 }], {
        duration: 2400,
        iterations: Infinity,
      })
    );
    for (const animation of spin) animation.pause();
    return frame;
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
    edge.style.opacity = "1";
    body.style.opacity = "1";
    if (docked) {
      docked = false;
      void body.getBoundingClientRect();
      place(innerWidth / 2, innerHeight / 2, ENTER_MS);
    }
    for (const animation of spin) animation.play();
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
