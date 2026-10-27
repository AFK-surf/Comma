// Page-side helpers of the agent browser. SalixAgent.Browser.Page evaluates
// this file in the "salix-browser" isolated world of a tab, so website scripts
// cannot see or change it. The world and its ref table live until the document
// navigates. Every function returns JSON data; errors are reason strings that
// match the driver's error vocabulary.
(() => {
  const S = globalThis.__salix || (globalThis.__salix = {
    refs: new Map(),
    byEl: new WeakMap(),
    next: 1,
  });

  const INTERACTIVE = new Set([
    "button", "link", "textbox", "searchbox", "checkbox", "radio", "switch",
    "combobox", "listbox", "slider", "spinbutton", "menuitem", "menuitemcheckbox",
    "menuitemradio", "tab", "option", "treeitem", "iframe",
  ]);
  const NAME_FROM_CONTENT = new Set([
    "button", "link", "heading", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "option", "treeitem", "cell", "columnheader", "rowheader",
    "gridcell", "tooltip",
  ]);
  const TEXT_ROLES = new Set([
    "paragraph", "listitem", "blockquote", "code", "status", "alert", "note",
    "caption", "term", "definition", "heading", "cell", "columnheader",
    "rowheader", "gridcell", "deletion", "insertion", "emphasis", "strong",
    "subscript", "superscript", "time",
  ]);
  const SKIP_TAGS = new Set([
    "script", "style", "noscript", "template", "head", "meta", "link", "title",
    "base", "object", "embed", "param", "source", "track", "map",
  ]);
  const INPUT_ROLES = {
    button: "button", submit: "button", reset: "button", image: "button",
    file: "button", checkbox: "checkbox", radio: "radio", range: "slider",
    number: "spinbutton", search: "searchbox",
  };
  const LANDMARKS = {
    nav: "navigation", main: "main", header: "banner", footer: "contentinfo",
    aside: "complementary", form: "form", article: "article", dialog: "dialog",
    ul: "list", ol: "list", menu: "list", li: "listitem", table: "table",
    tr: "row", td: "cell", thead: "rowgroup", tbody: "rowgroup", tfoot: "rowgroup",
    p: "paragraph", details: "group", fieldset: "group", hr: "separator",
    progress: "progressbar", meter: "meter", output: "status", blockquote: "blockquote",
    code: "code", iframe: "iframe", frame: "iframe", video: "video", audio: "audio",
    canvas: "canvas", option: "option", figure: "figure", time: "time",
    dialog: "dialog", textarea: "textbox", button: "button", summary: "button",
  };

  // An element with display: contents has no box of its own, so it is never
  // "visible", but its children are rendered.
  const boxless = (el) => el.ownerDocument.defaultView.getComputedStyle(el).display === "contents";

  const norm = (value) => String(value == null ? "" : value).replace(/\s+/g, " ").trim();
  const clip = (value, max) => (value.length > max ? value.slice(0, max - 1) + "…" : value);

  function roleOf(el) {
    const explicit = el.getAttribute("role");
    if (explicit) {
      const role = norm(explicit).split(" ")[0].toLowerCase();
      if (role === "presentation" || role === "none") return null;
      return role;
    }
    const tag = el.localName;
    switch (tag) {
      case "a":
      case "area":
        return el.hasAttribute("href") ? "link" : null;
      case "input": {
        const type = (el.getAttribute("type") || "text").toLowerCase();
        if (type === "hidden") return null;
        if (INPUT_ROLES[type]) return INPUT_ROLES[type];
        return el.hasAttribute("list") ? "combobox" : "textbox";
      }
      case "select":
        return el.multiple || el.size > 1 ? "listbox" : "combobox";
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
        return "heading";
      case "img":
        return el.getAttribute("alt") === "" ? null : "img";
      case "svg":
        return nameOf(el, "img") ? "img" : null;
      case "section":
        return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : null;
      case "th":
        return el.scope === "row" ? "rowheader" : "columnheader";
      default:
        if (LANDMARKS[tag]) return LANDMARKS[tag];
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return "textbox";
        return null;
    }
  }

  function interactive(el, role) {
    if (role && INTERACTIVE.has(role)) return true;
    if (el.localName === "summary") return true;
    const tabindex = el.getAttribute("tabindex");
    if (tabindex != null && Number(tabindex) >= 0 && !["body", "html"].includes(el.localName)) return true;
    return el.hasAttribute("onclick");
  }

  // Rendered text of an element: text nodes of visible descendants, image alt
  // text and aria-labels, through open shadow roots and slots.
  function textOf(el, skip) {
    let out = "";
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (child === skip) continue;
        if (child.nodeType === 3) out += child.nodeValue;
        else if (child.nodeType === 1) {
          if (SKIP_TAGS.has(child.localName) || child.hidden || child.getAttribute("aria-hidden") === "true") continue;
          if (child.localName !== "option" && !child.checkVisibility({ visibilityProperty: true })) {
            if (boxless(child)) walk(child);
            continue;
          }
          const label = child.getAttribute("aria-label") || (child.localName === "img" ? child.getAttribute("alt") : null);
          // A block, flex or grid item or table cell is a separate run of
          // text: <span>2062</span><span>0</span> in a flex row reads
          // "2062 0". Inline boxes, inline-block digits included, join.
          const display = child.ownerDocument.defaultView.getComputedStyle(child).display;
          const gap = display.startsWith("inline") || display === "contents" ? "" : " ";
          out += gap;
          if (label) out += " " + label + " ";
          else if (child.localName === "br") out += " ";
          else if (child.shadowRoot) walk(child.shadowRoot);
          else if (child.localName === "slot") for (const assigned of child.assignedNodes({ flatten: true })) walk({ childNodes: [assigned] });
          else walk(child);
          out += gap;
        }
      }
    };
    walk(el.shadowRoot && !el.childElementCount ? el.shadowRoot : el);
    return norm(out);
  }

  function nameOf(el, role) {
    const label = el.getAttribute("aria-label");
    if (norm(label)) return clip(norm(label), 200);
    const labelledby = el.getAttribute("aria-labelledby");
    if (labelledby) {
      const text = labelledby.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)).filter(Boolean).map(textOf).join(" ");
      if (norm(text)) return clip(norm(text), 200);
    }
    if (el.labels && el.labels.length) {
      const text = norm(Array.from(el.labels).map((label) => textOf(label, el)).join(" "));
      if (text) return clip(text, 200);
    }
    const tag = el.localName;
    if (tag === "input") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (["button", "submit", "reset"].includes(type)) return clip(norm(el.value) || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : ""), 200);
      if (type === "image") return clip(norm(el.alt || el.value), 200);
      const placeholder = el.getAttribute("placeholder");
      if (norm(placeholder)) return clip(norm(placeholder), 200);
    }
    if (tag === "textarea") {
      const placeholder = el.getAttribute("placeholder");
      if (norm(placeholder)) return clip(norm(placeholder), 200);
    }
    if (tag === "img" || tag === "area") return clip(norm(el.getAttribute("alt")), 200);
    if (tag === "table") {
      const caption = el.querySelector(":scope > caption");
      if (caption) return clip(textOf(caption), 200);
    }
    if (tag === "fieldset") {
      const legend = el.querySelector(":scope > legend");
      if (legend) return clip(textOf(legend), 200);
    }
    if (tag === "figure") {
      const caption = el.querySelector(":scope > figcaption");
      if (caption) return clip(textOf(caption), 200);
    }
    if (tag === "svg") {
      const title = el.querySelector(":scope > title");
      if (title) return clip(norm(title.textContent), 200);
    }
    if (tag === "iframe" || tag === "frame") return clip(norm(el.getAttribute("title") || el.getAttribute("name")), 200);
    if (role && (NAME_FROM_CONTENT.has(role) || TEXT_ROLES.has(role))) return textOf(el);
    const title = el.getAttribute("title");
    if (norm(title)) return clip(norm(title), 200);
    return "";
  }

  function visible(el) {
    if (!el.isConnected) return false;
    if (el.localName === "option") return visible(el.closest("select") || el.parentElement);
    if (!el.checkVisibility({ visibilityProperty: true })) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  // The driver owns the ref counter. reset clears the table after the driver
  // lost its view of this document (restart) so old refs cannot alias new ones.
  function begin(opts) {
    if (opts.reset) {
      S.refs = new Map();
      S.byEl = new WeakMap();
    }
    S.next = Math.max(S.next, opts.next || 1, 1);
  }

  function refFor(el) {
    let ref = S.byEl.get(el);
    if (!ref) {
      if (S.refs.size > 5000) for (const [key, value] of S.refs) if (!value.isConnected) S.refs.delete(key);
      ref = "e" + S.next++;
      S.byEl.set(el, ref);
      S.refs.set(ref, el);
    }
    return ref;
  }

  function sameOriginDocument(frame) {
    try {
      const doc = frame.contentDocument;
      return doc && doc.body ? doc : null;
    } catch (_) {
      return null;
    }
  }

  function describe(el) {
    const role = roleOf(el) || "generic";
    const name = nameOf(el, role);
    return { ref: refFor(el), role, name: clip(name, 80) };
  }

  function states(el, role) {
    const parts = [];
    const tag = el.localName;
    if (role === "heading") {
      const level = el.getAttribute("aria-level") || (/^h[1-6]$/.test(tag) ? tag[1] : null);
      if (level) parts.push("level=" + level);
    }
    if (role === "link") {
      const href = el.href || el.getAttribute("href");
      if (href && !/^javascript:/i.test(href)) parts.push("href=" + clip(String(href), 120));
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      const type = tag === "input" ? (el.getAttribute("type") || "text").toLowerCase() : null;
      if (type === "checkbox" || type === "radio") parts.push(el.checked ? "checked" : "unchecked");
      else if (type === "password") parts.push("type=password", el.value ? "filled" : "empty");
      else if (type && ["button", "submit", "reset", "image", "file"].includes(type)) {
        if (type === "file") parts.push("type=file");
      } else if (tag === "select") {
        const selected = Array.from(el.selectedOptions).map((option) => norm(option.label || option.textContent));
        parts.push('value="' + clip(selected.join(", "), 100) + '"');
      } else {
        if (type && type !== "text") parts.push("type=" + type);
        parts.push('value="' + clip(norm(el.value), 100) + '"');
      }
      if (el.disabled) parts.push("disabled");
      if (el.required) parts.push("required");
      if (el.readOnly) parts.push("readonly");
      if (el.validity && !el.validity.valid && el.value) parts.push("invalid");
    } else {
      if (el.isContentEditable && role === "textbox") parts.push('value="' + clip(textOf(el), 100) + '"');
      if (el.matches(":disabled") || el.getAttribute("aria-disabled") === "true") parts.push("disabled");
      const checked = el.getAttribute("aria-checked");
      if (checked) parts.push(checked === "true" ? "checked" : checked === "mixed" ? "mixed" : "unchecked");
      const pressed = el.getAttribute("aria-pressed");
      if (pressed) parts.push("pressed=" + pressed);
      const selected = el.getAttribute("aria-selected");
      if (selected === "true") parts.push("selected");
      if (role === "option" && el.selected) parts.push("selected");
    }
    const expanded = el.getAttribute("aria-expanded");
    if (expanded) parts.push("expanded=" + expanded);
    if (tag === "summary" && el.parentElement && el.parentElement.localName === "details") parts.push("expanded=" + el.parentElement.open);
    if (el.getAttribute("aria-haspopup") && el.getAttribute("aria-haspopup") !== "false") parts.push("haspopup");
    if (el.getAttribute("aria-current") && el.getAttribute("aria-current") !== "false") parts.push("current");
    if (el.getAttribute("aria-invalid") === "true") parts.push("invalid");
    if (el.ownerDocument.activeElement === el) parts.push("focused");
    return parts;
  }

  // Builds the text snapshot. opts: scope ("viewport" | "full" | "subtree"),
  // root (ref for subtree), interactiveOnly, maxChars, next, reset.
  function snapshot(opts) {
    begin(opts);
    const budget = Math.max(200, opts.maxChars || 12000);
    const viewportOnly = opts.scope === "viewport";
    const lines = [];
    let chars = 0;
    let truncated = false;
    let root = document.body || document.documentElement;
    if (opts.scope === "subtree") {
      const target = S.refs.get(opts.root);
      if (!target || !target.isConnected) return { error: "stale_element" };
      root = target;
    }
    const emit = (depth, text) => {
      const line = "  ".repeat(depth) + "- " + text;
      if (truncated || chars + line.length + 1 > budget) {
        truncated = true;
        return false;
      }
      lines.push(line);
      chars += line.length + 1;
      return true;
    };
    const quote = (name) => (name ? ' "' + name.replace(/"/g, "'") + '"' : "");
    // The viewport clip of a frame in top-level coordinates. The top document
    // starts with the window viewport.
    const intersects = (rect, clipRect) =>
      rect.width === 0 && rect.height === 0
        ? true
        : rect.bottom > clipRect.top && rect.top < clipRect.bottom && rect.right > clipRect.left && rect.left < clipRect.right;

    const visit = (node, depth, ctx) => {
      if (truncated) return;
      if (node.nodeType === 3) {
        if (ctx.interactiveOnly) return;
        const text = norm(node.nodeValue);
        if (text) ctx.buffer.push(text);
        return;
      }
      if (node.nodeType !== 1) return;
      const el = node;
      if (SKIP_TAGS.has(el.localName)) return;
      if (el.hidden || el.getAttribute("aria-hidden") === "true") return;
      if (el.localName !== "option" && !el.checkVisibility({ visibilityProperty: true })) {
        if (boxless(el)) visitChildren(el, depth, ctx);
        return;
      }
      const rect = el.localName === "option" ? null : el.getBoundingClientRect();
      if (viewportOnly && rect) {
        const shifted = {
          top: rect.top + ctx.offset.y, bottom: rect.bottom + ctx.offset.y,
          left: rect.left + ctx.offset.x, right: rect.right + ctx.offset.x,
          width: rect.width, height: rect.height,
        };
        if (!intersects(shifted, ctx.clip)) return;
      }
      const role = roleOf(el);
      const isInteractive = interactive(el, role);
      if (!role && !isInteractive) {
        if (el.localName === "label" && el.control && !ctx.interactiveOnly) {
          flush(depth, ctx);
          visitChildren(el, depth, { ...ctx, interactiveOnly: true, buffer: [] });
          return;
        }
        visitChildren(el, depth, ctx);
        return;
      }
      if (ctx.interactiveOnly && !isInteractive && role !== "heading" && role !== "iframe") {
        visitChildren(el, depth, ctx);
        return;
      }
      flush(depth, ctx);
      const name = nameOf(el, role);
      if (role === "img" && !name) return;
      let line = (role || "generic") + quote(clip(name, 200));
      if (isInteractive) line += " [" + refFor(el) + "]";
      const extra = states(el, role);
      if (extra.length) line += " " + extra.join(" ");
      if (!emit(depth, line)) return;
      if (el.localName === "select") {
        const options = Array.from(el.options);
        for (const option of options.slice(0, 30)) {
          emit(depth + 1, "option" + quote(clip(norm(option.label || option.textContent), 100)) + (option.selected ? " selected" : "") + (option.disabled ? " disabled" : ""));
        }
        if (options.length > 30) emit(depth + 1, "… " + (options.length - 30) + " more options");
        return;
      }
      if (el.localName === "svg" || el.localName === "img" || el.localName === "canvas" || el.localName === "video" || el.localName === "audio") return;
      if (role === "iframe") {
        const doc = sameOriginDocument(el);
        if (!doc) {
          emit(depth + 1, "text: [cross-origin frame content is not captured]");
          return;
        }
        if (ctx.frames >= 8) return;
        const frameRect = rect || el.getBoundingClientRect();
        const offset = { x: ctx.offset.x + frameRect.left + el.clientLeft, y: ctx.offset.y + frameRect.top + el.clientTop };
        const clipRect = {
          top: Math.max(ctx.clip.top, frameRect.top + ctx.offset.y), bottom: Math.min(ctx.clip.bottom, frameRect.bottom + ctx.offset.y),
          left: Math.max(ctx.clip.left, frameRect.left + ctx.offset.x), right: Math.min(ctx.clip.right, frameRect.right + ctx.offset.x),
        };
        const inner = { ...ctx, offset, clip: clipRect, buffer: [], frames: ctx.frames + 1 };
        visitChildren(doc.body, depth + 1, inner);
        flush(depth + 1, inner);
        return;
      }
      const nameFromContent = role && (NAME_FROM_CONTENT.has(role) || TEXT_ROLES.has(role));
      const inner = { ...ctx, buffer: [], interactiveOnly: ctx.interactiveOnly || nameFromContent || (isInteractive && !role) };
      if (isInteractive && !role && !ctx.interactiveOnly) {
        // A clickable container without a role: show its text once.
        const text = textOf(el);
        if (text) emit(depth + 1, "text: " + clip(text, 300));
      }
      visitChildren(el, depth + 1, inner);
      flush(depth + 1, inner);
    };

    const visitChildren = (el, depth, ctx) => {
      if (el.shadowRoot) {
        for (const child of el.shadowRoot.childNodes) visit(child, depth, ctx);
        return;
      }
      if (el.localName === "slot") {
        for (const assigned of el.assignedNodes({ flatten: true })) visit(assigned, depth, ctx);
        return;
      }
      for (const child of el.childNodes) visit(child, depth, ctx);
    };

    const flush = (depth, ctx) => {
      if (!ctx.buffer.length) return;
      const text = norm(ctx.buffer.join(" "));
      ctx.buffer.length = 0;
      if (text) emit(depth, "text: " + text);
    };

    const ctx = {
      offset: { x: 0, y: 0 },
      clip: { top: 0, left: 0, bottom: innerHeight, right: innerWidth },
      buffer: [],
      interactiveOnly: Boolean(opts.interactiveOnly),
      frames: 0,
    };
    if (opts.scope === "subtree") visit(root, 0, ctx);
    else visitChildren(root, 0, ctx);
    flush(0, ctx);
    const scrolling = document.scrollingElement || document.documentElement;
    return {
      url: location.href.slice(0, 4096),
      title: document.title.slice(0, 256),
      text: lines.join("\n"),
      truncated,
      next: S.next,
      scrollY: Math.round(scrolling.scrollTop),
      scrollX: Math.round(scrolling.scrollLeft),
      pageHeight: Math.round(scrolling.scrollHeight),
      pageWidth: Math.round(scrolling.scrollWidth),
      viewportHeight: innerHeight,
      viewportWidth: innerWidth,
    };
  }

  // Every element of the document, open shadow roots and same-origin frames.
  function* allElements(doc, depth = 0) {
    const walk = function* (root) {
      for (const el of root.querySelectorAll("*")) {
        if (SKIP_TAGS.has(el.localName)) continue;
        yield el;
        if (el.shadowRoot) yield* walk(el.shadowRoot);
        if ((el.localName === "iframe" || el.localName === "frame") && depth < 8) {
          const inner = sameOriginDocument(el);
          if (inner) yield* allElements(inner, depth + 1);
        }
      }
    };
    yield* walk(doc);
  }

  function queryAll(selector) {
    const out = [];
    const walk = (root, depth) => {
      for (const el of root.querySelectorAll(selector)) {
        out.push(el);
        if (out.length >= 200) return;
      }
      for (const el of root.querySelectorAll("*")) {
        if (el.shadowRoot) walk(el.shadowRoot, depth);
        if ((el.localName === "iframe" || el.localName === "frame") && depth < 8) {
          const inner = sameOriginDocument(el);
          if (inner) walk(inner, depth + 1);
        }
        if (out.length >= 200) return;
      }
    };
    walk(document, 0);
    return out;
  }

  function childElements(el) {
    if (el.shadowRoot) return Array.from(el.shadowRoot.children);
    if (el.localName === "slot") return el.assignedElements({ flatten: true });
    return Array.from(el.children);
  }

  function interactiveAncestor(el) {
    let node = el;
    while (node && node.nodeType === 1) {
      if (interactive(node, roleOf(node))) return node;
      node = node.parentElement || (node.getRootNode() instanceof ShadowRoot ? node.getRootNode().host : null);
    }
    return null;
  }

  function byText(text, exact) {
    const wanted = norm(text);
    const lower = wanted.toLowerCase();
    const matches = (el) => {
      const own = textOf(el);
      return exact ? own === wanted : own.toLowerCase().includes(lower);
    };
    const innermost = [];
    for (const el of allElements(document)) {
      if (!matches(el)) continue;
      let childMatches = false;
      for (const child of childElements(el)) if (matches(child)) { childMatches = true; break; }
      if (!childMatches && visible(el)) innermost.push(el);
    }
    const out = new Set();
    for (const el of innermost) out.add(interactiveAncestor(el) || el);
    return Array.from(out);
  }

  function byRole(role, name) {
    const wantedRole = norm(role).toLowerCase();
    const wantedName = name == null ? null : norm(name).toLowerCase();
    const exact = [];
    const partial = [];
    for (const el of allElements(document)) {
      const actual = roleOf(el) || (interactive(el, null) ? "generic" : null);
      if (actual !== wantedRole) continue;
      if (wantedName == null) {
        if (visible(el)) exact.push(el);
        continue;
      }
      if (!visible(el)) continue;
      const actualName = nameOf(el, actual).toLowerCase();
      if (actualName === wantedName) exact.push(el);
      else if (actualName.includes(wantedName)) partial.push(el);
    }
    return exact.length ? exact : partial;
  }

  // Resolves a target to a ref. target: {ref} | {selector} | {text, exact} | {role, name}.
  function resolve(target, opts) {
    begin(opts);
    if (target.ref) {
      const el = S.refs.get(target.ref);
      if (!el || !el.isConnected) return { error: "stale_element", next: S.next };
      return { ref: target.ref, next: S.next };
    }
    let matches;
    if (target.selector != null) {
      try {
        matches = queryAll(target.selector).filter(visible);
      } catch (_) {
        return { error: "invalid_input", next: S.next };
      }
    } else if (target.text != null) matches = byText(target.text, Boolean(target.exact));
    else if (target.role != null) matches = byRole(target.role, target.name);
    else return { error: "invalid_input", next: S.next };
    if (matches.length === 0) return { error: "target_not_found", next: S.next };
    if (matches.length > 1) return { error: "ambiguous_target", count: matches.length, candidates: matches.slice(0, 6).map(describe), next: S.next };
    return { ref: refFor(matches[0]), next: S.next };
  }

  function element(ref) {
    const el = S.refs.get(ref);
    return el && el.isConnected ? el : null;
  }

  // The element at a point. elementFromPoint on a document stops at a shadow
  // host: descend into open shadow roots until the hit is `el` or inside it.
  function hitAt(doc, x, y, el) {
    let hit = doc.elementFromPoint(x, y);
    while (hit && hit !== el && !(el && el.contains(hit)) && hit.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  }

  // Scrolls the element into view and returns its click point in top-level
  // viewport coordinates, or a reason why it cannot be clicked now.
  async function clickPoint(el) {
    if (!el.isConnected) return { error: "stale_element" };
    if (el.localName === "option") {
      return { error: "invalid_input" };
    }
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const win = el.ownerDocument.defaultView;
    const rect = el.getBoundingClientRect();
    const left = Math.max(0, rect.left);
    const top = Math.max(0, rect.top);
    const right = Math.min(win.innerWidth, rect.right);
    const bottom = Math.min(win.innerHeight, rect.bottom);
    let x = left + (right - left) / 2;
    let y = top + (bottom - top) / 2;
    if (!rect.width || !rect.height || right <= left || bottom <= top || el.matches(":disabled")) return { error: "browser_operation_failed" };
    const hit = hitAt(el.ownerDocument, x, y, el);
    const inside = (node) => node === el || el.contains(node) || Boolean(el.shadowRoot && el.shadowRoot.contains(node));
    if (!hit || !inside(hit)) return { error: "browser_operation_failed" };
    // In a frame, the point must also reach the frame element in every
    // parent document: something drawn over the frame would take the click.
    let frame = win;
    while (frame !== frame.parent) {
      const owner = frame.frameElement;
      if (!owner) break;
      const frameRect = owner.getBoundingClientRect();
      x += frameRect.left + owner.clientLeft;
      y += frameRect.top + owner.clientTop;
      if (hitAt(owner.ownerDocument, x, y) !== owner) return { error: "browser_operation_failed" };
      frame = frame.parent;
    }
    return { x, y };
  }

  // Prepares a field for Input.insertText: focus and select its content.
  function prepareFill(el) {
    if (!el.isConnected) return "stale_element";
    if (el.matches(":disabled") || el.readOnly || !el.getClientRects().length) return "browser_operation_failed";
    el.focus();
    if (el instanceof el.ownerDocument.defaultView.HTMLInputElement || el instanceof el.ownerDocument.defaultView.HTMLTextAreaElement) {
      if (el.localName === "input" && !["text", "search", "url", "tel", "email", "password", "number"].includes(el.type)) return "invalid_input";
      el.select();
      return null;
    }
    if (el.isContentEditable) {
      const doc = el.ownerDocument;
      const range = doc.createRange();
      range.selectNodeContents(el);
      const selection = doc.defaultView.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      return null;
    }
    return "invalid_input";
  }

  function numberFill(el, text) {
    return el.localName === "input" && el.type === "number" && text !== "" && !Number.isFinite(Number(text)) ? "invalid_input" : null;
  }

  // Selects an option of a <select> by value or by visible label.
  function selectOption(el, value) {
    if (!el.isConnected) return "stale_element";
    if (el.localName !== "select") return "invalid_input";
    if (el.disabled) return "browser_operation_failed";
    const wanted = norm(value);
    const options = Array.from(el.options);
    const option = options.find((item) => item.value === value) ||
      options.find((item) => norm(item.label || item.textContent) === wanted) ||
      options.find((item) => norm(item.label || item.textContent).toLowerCase() === wanted.toLowerCase());
    if (!option) return "target_not_found";
    if (option.disabled) return "browser_operation_failed";
    el.focus();
    if (el.multiple) option.selected = true;
    else el.value = option.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return null;
  }

  function scrollBy(x, y) {
    const scrolling = document.scrollingElement || document.documentElement;
    scrolling.scrollBy({ left: x, top: y, behavior: "instant" });
    return { scrollX: Math.round(scrolling.scrollLeft), scrollY: Math.round(scrolling.scrollTop) };
  }

  function scrollTo(el) {
    if (!el.isConnected) return "stale_element";
    el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
    return null;
  }

  // Wait conditions. Returns true when the condition holds now.
  function check(condition) {
    if (condition.text != null) {
      const wanted = norm(condition.text).toLowerCase();
      if (!wanted) return true;
      const docs = [document];
      for (const el of allElements(document)) {
        if (el.localName === "iframe" || el.localName === "frame") {
          const inner = sameOriginDocument(el);
          if (inner && docs.length < 9) docs.push(inner);
        }
      }
      return docs.some((doc) => doc.body && textOf(doc.body).toLowerCase().includes(wanted));
    }
    if (condition.selector != null) {
      try {
        return queryAll(condition.selector).some(visible);
      } catch (_) {
        return { error: "invalid_input" };
      }
    }
    return true;
  }

  Object.assign(S, { snapshot, resolve, element, clickPoint, prepareFill, numberFill, selectOption, scrollTo, scrollBy, check, describe });
  return true;
})();
