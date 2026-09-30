// Contenteditable composer with /-skill mentions (Claude-style): typing "/"
// opens a filterable skill menu; a selected skill becomes an atomic inline
// chip (blue token, hover reveals × + a description popover). The editable
// region lives inside phx-update="ignore" — this hook owns it and mirrors its
// content into two hidden inputs (chat[text] plain text, chat[skills] JSON)
// so the regular LiveView form pipeline (phx-change / phx-submit / data-ready)
// stays untouched. Skills arrive via the form's data-skills attribute, which
// sits OUTSIDE the ignored subtree so late loads still patch through.
const MAX_MENU_ITEMS = 8;

const MENU_CLASS =
  "skill-mention-menu t-dropdown-enter fixed z-50 min-w-56 max-w-72 overflow-y-auto " +
  "rounded-lg bg-white py-1 shadow-popover ring-1 ring-neutral-200";

const POPOVER_CLASS =
  "skill-mention-popover t-dropdown-enter pointer-events-none fixed z-50 max-w-64 " +
  "rounded-lg bg-white p-3 shadow-popover ring-1 ring-neutral-200";

export const SkillComposer = {
  mounted() {
    this.editor = this.el.querySelector("[contenteditable]");
    this.textInput = this.el.querySelector("[data-skill-text]");
    this.jsonInput = this.el.querySelector("[data-skill-json]");
    if (!this.editor || !this.textInput || !this.jsonInput) return;

    this.multiline = this.el.dataset.multiline === "true";
    this.skills = this.parseSkills();
    this.composing = false;
    this.trigger = null;
    this.results = [];
    this.activeIndex = 0;

    this.menu = document.createElement("div");
    this.menu.className = MENU_CLASS;
    this.menu.style.maxHeight = "16rem";
    this.menu.setAttribute("role", "listbox");
    this.menu.hidden = true;
    document.body.appendChild(this.menu);

    this.popover = document.createElement("div");
    this.popover.className = POPOVER_CLASS;
    this.popover.hidden = true;
    document.body.appendChild(this.popover);

    // Selecting with the mouse must win over the editor's blur.
    this.menu.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const item = e.target.closest("[data-index]");
      if (item) this.selectSkill(this.results[Number(item.dataset.index)]);
    });

    this.editor.addEventListener("keydown", (e) => this.onKeydown(e));
    this.editor.addEventListener("input", () => this.onInput());
    this.editor.addEventListener("paste", (e) => this.onPaste(e));
    this.editor.addEventListener(
      "compositionstart",
      () => (this.composing = true),
    );
    this.editor.addEventListener("compositionend", () => {
      this.composing = false;
      this.detectTrigger();
    });

    // Caret movement (arrows, clicks) opens/closes the menu too — the
    // listener only lives while the editor is focused.
    this.onSelectionChange = () => this.detectTrigger();
    this.editor.addEventListener("focus", () =>
      document.addEventListener("selectionchange", this.onSelectionChange),
    );
    this.editor.addEventListener("blur", () => {
      document.removeEventListener("selectionchange", this.onSelectionChange);
      this.closeMenu();
    });

    // × on a chip removes it; both fixed-position layers follow the chip on
    // hover and close on any scroll (capture: the composer sits inside the
    // page's inner scroll columns).
    this.editor.addEventListener("mousedown", (e) => {
      const remove = e.target.closest(".skill-chip-remove");
      if (!remove) return;
      e.preventDefault();
      this.removeChip(remove.closest("[data-skill-chip]"));
    });
    this.editor.addEventListener("mouseover", (e) => {
      const chip = e.target.closest("[data-skill-chip]");
      if (chip && this.editor.contains(chip)) this.schedulePopover(chip);
    });
    this.editor.addEventListener("mouseout", (e) => {
      const chip = e.target.closest("[data-skill-chip]");
      if (chip && !chip.contains(e.relatedTarget)) this.hidePopover();
    });

    // The + menu items carry the accept list they stand for: swap it onto
    // the file input and open the picker synchronously — inside the click's
    // transient user activation, or the browser refuses to show the dialog.
    this.el.addEventListener("click", (e) => {
      const item = e.target.closest("[data-upload-accept]");
      if (!item) return;
      const fileInput = this.el.querySelector('input[type="file"]');
      if (!fileInput) return;
      fileInput.accept = item.dataset.uploadAccept;
      fileInput.click();
    });
    this.onScroll = () => {
      this.closeMenu();
      this.hidePopover();
    };
    window.addEventListener("scroll", this.onScroll, {
      capture: true,
      passive: true,
    });
    window.addEventListener("resize", this.onScroll);

    // Clear right after submit is queued — same focused-input rationale as
    // ResetOnSubmit, but explicit: the hidden inputs' defaultValue is the
    // stale server render, so form.reset() would resurrect it.
    this.el.addEventListener("submit", () => {
      this.syncInputs();
      window.requestAnimationFrame(() => {
        this.editor.replaceChildren();
        this.textInput.value = "";
        this.jsonInput.value = "[]";
        this.notifyChange();
        this.closeMenu();
        this.hidePopover();
      });
    });

    this.applyReadyState();
  },

  updated() {
    // Skills load behind :ready — refresh the pool and any open menu.
    this.skills = this.parseSkills();
    this.applyReadyState();
    if (document.activeElement === this.editor) this.detectTrigger();
  },

  destroyed() {
    clearTimeout(this.popoverTimer);
    this.menu?.remove();
    this.popover?.remove();
    document.removeEventListener("selectionchange", this.onSelectionChange);
    window.removeEventListener("scroll", this.onScroll, { capture: true });
    window.removeEventListener("resize", this.onScroll);
  },

  parseSkills() {
    try {
      const skills = JSON.parse(this.el.dataset.skills || "[]");
      return Array.isArray(skills)
        ? skills.filter((s) => s && s.name && s.location)
        : [];
    } catch {
      return [];
    }
  },

  // The composer mirrors the old input's disabled state, and the placeholder
  // follows the form's data-placeholder-text — the editor sits inside
  // phx-update="ignore", so server-side placeholder changes (assistant thread
  // vs focused task) only reach it through here.
  applyReadyState() {
    const placeholder = this.el.dataset.placeholderText;
    if (placeholder && this.editor.dataset.placeholder !== placeholder) {
      this.editor.dataset.placeholder = placeholder;
      this.editor.setAttribute("aria-label", placeholder);
    }

    const ready = this.el.dataset.ready === "true";
    this.editor.setAttribute("contenteditable", ready ? "true" : "false");
    this.editor.classList.toggle("opacity-50", !ready);
    // Autofocus must wait for ready: contenteditable="false" isn't focusable,
    // so a focus() at mount time (chat still :loading) silently fails.
    if (ready && this.el.dataset.autofocus === "true" && !this.didAutofocus) {
      this.didAutofocus = true;
      this.editor.focus();
    }
  },

  // ---- serialization: the editable DOM is the single source of truth ----

  serialize() {
    const walk = (node) => {
      if (node.nodeType === Node.TEXT_NODE)
        return node.data.replace(/\u00A0/g, " ");
      if (node.nodeType !== Node.ELEMENT_NODE) return "";
      if (node.hasAttribute?.("data-skill-chip"))
        return "/" + node.dataset.name;
      if (node.tagName === "BR") return "\n";
      const inner = [...node.childNodes].map(walk).join("");
      // Browsers wrap stray lines in divs; treat them as line breaks.
      return /^(DIV|P)$/.test(node.tagName) ? "\n" + inner : inner;
    };
    return [...this.editor.childNodes].map(walk).join("");
  },

  chipEntries() {
    return [...this.editor.querySelectorAll("[data-skill-chip]")].map(
      (chip) => ({
        name: chip.dataset.name,
        location: chip.dataset.location,
      }),
    );
  },

  syncInputs() {
    this.textInput.value = this.serialize();
    this.jsonInput.value = JSON.stringify(this.chipEntries());
    this.notifyChange();
  },

  // The synthetic input event bubbles to the form and drives phx-change
  // (validate_chat keeps @chat_text in sync server-side).
  notifyChange() {
    this.textInput.dispatchEvent(new Event("input", { bubbles: true }));
  },

  onInput() {
    // Native edits (select-all delete, cut, undo) remove chips without any
    // mouseout or removeChip call — drop the popover once its chip is gone.
    if (this.popoverChip && !this.popoverChip.isConnected) this.hidePopover();

    // A stray <br> survives deleting everything and defeats :empty (the CSS
    // placeholder), so normalize a visually-empty editor to actually empty.
    if (
      !this.editor.querySelector("[data-skill-chip]") &&
      this.editor.innerText.trim() === "" &&
      this.editor.childNodes.length > 0
    ) {
      this.editor.replaceChildren();
    }
    this.syncInputs();
    this.detectTrigger();
  },

  // ---- keys ----

  onKeydown(e) {
    if (!this.menu.hidden) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const step = e.key === "ArrowDown" ? 1 : -1;
        this.setActive(
          (this.activeIndex + step + this.results.length) % this.results.length,
        );
        return;
      }
      if ((e.key === "Enter" || e.key === "Tab") && !e.isComposing) {
        e.preventDefault();
        e.stopPropagation();
        this.selectSkill(this.results[this.activeIndex]);
        return;
      }
      if (e.key === "Escape") {
        // First Escape closes the menu; the sheet's window keydown only
        // collapses the chat on the next one.
        e.preventDefault();
        e.stopPropagation();
        this.closeMenu();
        return;
      }
    }

    if (
      (e.key === "Backspace" || e.key === "Delete") &&
      this.deleteAdjacentChip(e)
    )
      return;

    if (e.key !== "Enter" || e.isComposing || e.keyCode === 229) return;
    if (this.multiline && e.shiftKey) {
      e.preventDefault();
      this.insertLineBreak();
      return;
    }
    e.preventDefault();
    if (e.shiftKey) return;
    if (this.el.dataset.ready === "true") {
      this.syncInputs();
      this.el.requestSubmit();
    }
  },

  // Chips delete atomically. Chrome treats contenteditable="false" islands as
  // one unit natively, Firefox does not — the explicit handler unifies both.
  deleteAdjacentChip(e) {
    const sel = window.getSelection();
    if (!sel || !sel.isCollapsed || sel.rangeCount === 0) return false;
    const { anchorNode, anchorOffset } = sel;
    if (!this.editor.contains(anchorNode)) return false;

    const backwards = e.key === "Backspace";
    let neighbor = null;

    if (anchorNode.nodeType === Node.TEXT_NODE) {
      if (backwards && anchorOffset === 0)
        neighbor = anchorNode.previousSibling;
      if (!backwards && anchorOffset === anchorNode.data.length)
        neighbor = anchorNode.nextSibling;
    } else if (anchorNode === this.editor) {
      neighbor = backwards
        ? this.editor.childNodes[anchorOffset - 1]
        : this.editor.childNodes[anchorOffset];
    }

    if (!neighbor?.hasAttribute?.("data-skill-chip")) return false;
    e.preventDefault();
    this.removeChip(neighbor, { keepSpace: true });
    return true;
  },

  removeChip(chip, { keepSpace = false } = {}) {
    if (!chip) return;
    const space = chip.nextSibling;
    if (
      !keepSpace &&
      space?.nodeType === Node.TEXT_NODE &&
      space.data.startsWith("\u00A0")
    ) {
      space.data = space.data.slice(1);
    }
    chip.remove();
    this.editor.normalize();
    this.hidePopover();
    this.syncInputs();
  },

  insertLineBreak() {
    const range = this.caretRange();
    if (!range) return;
    range.deleteContents();
    const br = document.createElement("br");
    range.insertNode(br);
    // insertNode splits the text node and can leave an empty fragment after
    // the <br> — normalize first, or the padding check below sees it and a
    // lone trailing <br> renders no new line (Chrome then snaps the caret
    // back BEFORE the break and the next keystroke lands on the old line).
    this.editor.normalize();
    if (!br.nextSibling) br.after(document.createElement("br"));
    this.placeCaretAfter(br);
    this.onInput();
  },

  onPaste(e) {
    e.preventDefault();
    let text = e.clipboardData?.getData("text/plain") || "";
    if (!text) return;
    if (!this.multiline) text = text.replace(/\s*\n\s*/g, " ");

    const range = this.caretRange();
    if (!range) return;
    range.deleteContents();

    // Plain text only; \n becomes <br> so serialize() round-trips it.
    const fragment = document.createDocumentFragment();
    const lines = text.split("\n");
    let last = null;
    lines.forEach((line, i) => {
      if (i > 0) fragment.appendChild(document.createElement("br"));
      if (line !== "")
        fragment.appendChild((last = document.createTextNode(line)));
    });
    last = fragment.lastChild;
    range.insertNode(fragment);
    if (last)
      this.placeCaretAfter(
        last,
        last.nodeType === Node.TEXT_NODE ? last.length : null,
      );
    this.onInput();
  },

  caretRange() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    const range = sel.getRangeAt(0);
    return this.editor.contains(range.startContainer) ? range : null;
  },

  placeCaretAfter(node, offset = null) {
    const sel = window.getSelection();
    const range = document.createRange();
    if (offset !== null) {
      range.setStart(node, offset);
    } else {
      range.setStartAfter(node);
    }
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
  },

  // ---- / trigger + menu ----

  detectTrigger() {
    if (this.composing || this.skills.length === 0) return this.closeMenu();
    const sel = window.getSelection();
    if (!sel || !sel.isCollapsed || sel.rangeCount === 0)
      return this.closeMenu();
    const node = sel.anchorNode;
    if (
      !node ||
      node.nodeType !== Node.TEXT_NODE ||
      !this.editor.contains(node)
    ) {
      return this.closeMenu();
    }

    // Only the current text node matters: a chip boundary starts a fresh
    // node, so "/" right after a chip still matches at ^. Requiring a
    // whitespace (or line-start) prefix keeps URLs and paths from
    // triggering mid-word.
    const before = node.data.slice(0, sel.anchorOffset).replace(/\u00A0/g, " ");
    const match = before.match(/(^|\s)\/([^/\n]*)$/);
    if (!match) return this.closeMenu();

    this.trigger = { node, offset: match.index + match[1].length };
    this.openMenu(match[2]);
  },

  filterSkills(query) {
    const q = query.trim().toLowerCase();
    const mentioned = new Set(this.chipEntries().map((c) => c.location));
    const pool = this.skills.filter((s) => !mentioned.has(s.location));
    if (q === "") return pool.slice(0, MAX_MENU_ITEMS);

    return pool
      .map((skill) => {
        const name = skill.name.toLowerCase();
        const description = (skill.description || "").toLowerCase();
        let rank = null;
        if (name.startsWith(q)) rank = 0;
        else if (name.includes(q)) rank = 1;
        else if (description.includes(q)) rank = 2;
        return rank === null ? null : { skill, rank };
      })
      .filter(Boolean)
      .sort((a, b) => a.rank - b.rank)
      .slice(0, MAX_MENU_ITEMS)
      .map((entry) => entry.skill);
  },

  openMenu(query) {
    this.results = this.filterSkills(query);
    if (this.results.length === 0) return this.closeMenu();

    const wasOpen = !this.menu.hidden;
    this.menu.replaceChildren(
      ...this.results.map((skill, index) => {
        const item = document.createElement("button");
        item.type = "button";
        item.dataset.index = String(index);
        item.setAttribute("role", "option");
        item.className =
          "block w-full cursor-pointer px-3 py-1.5 text-left hover:bg-neutral-100";
        const name = document.createElement("div");
        name.className = "truncate text-[13px] font-medium text-neutral-900";
        name.textContent = skill.name;
        item.appendChild(name);
        if (skill.description) {
          const description = document.createElement("div");
          description.className = "truncate text-xs text-neutral-500";
          description.textContent = skill.description;
          item.appendChild(description);
        }
        return item;
      }),
    );
    this.setActive(0);

    // Re-running the enter animation on every keystroke would flicker.
    if (wasOpen) this.menu.classList.remove("t-dropdown-enter");
    this.menu.hidden = false;
    this.positionMenu();
  },

  setActive(index) {
    this.activeIndex = index;
    [...this.menu.children].forEach((item, i) => {
      item.classList.toggle("bg-neutral-100", i === index);
      item.setAttribute("aria-selected", String(i === index));
      if (i === index) item.scrollIntoView({ block: "nearest" });
    });
  },

  positionMenu() {
    const sel = window.getSelection();
    let anchor = sel?.rangeCount
      ? sel.getRangeAt(0).getBoundingClientRect()
      : null;
    // A collapsed range at a line start reports a zero rect — fall back.
    if (
      !anchor ||
      (anchor.width === 0 && anchor.height === 0 && anchor.top === 0)
    ) {
      anchor = this.editor.getBoundingClientRect();
    }

    const rect = this.menu.getBoundingClientRect();
    const left = Math.max(
      8,
      Math.min(anchor.left, window.innerWidth - rect.width - 8),
    );
    let top = anchor.bottom + 6;
    if (top + rect.height > window.innerHeight - 8)
      top = anchor.top - rect.height - 6;
    this.menu.style.left = `${left}px`;
    this.menu.style.top = `${Math.max(8, top)}px`;
  },

  closeMenu() {
    if (this.menu.hidden) return;
    this.menu.hidden = true;
    this.menu.classList.add("t-dropdown-enter");
    this.trigger = null;
    this.results = [];
  },

  selectSkill(skill) {
    if (!skill || !this.trigger) return;
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;

    // Replace "/query" (from the stored / up to the caret) with the chip.
    const range = document.createRange();
    range.setStart(this.trigger.node, this.trigger.offset);
    range.setEnd(sel.anchorNode, sel.anchorOffset);
    range.deleteContents();

    const chip = this.buildChip(skill);
    range.insertNode(chip);
    const space = document.createTextNode("\u00A0");
    chip.after(space);
    this.placeCaretAfter(space, 1);
    this.editor.normalize();

    this.closeMenu();
    this.syncInputs();
  },

  // Built with createElement — names and descriptions are skill-author
  // controlled and must never hit innerHTML.
  buildChip(skill) {
    const chip = document.createElement("span");
    chip.setAttribute("contenteditable", "false");
    chip.setAttribute("data-skill-chip", "");
    chip.dataset.name = skill.name;
    chip.dataset.location = skill.location;
    chip.className = "skill-chip";

    const label = document.createElement("span");
    label.textContent = `/${skill.name}`;
    chip.appendChild(label);

    const remove = document.createElement("button");
    remove.type = "button";
    remove.tabIndex = -1;
    remove.className = "skill-chip-remove";
    remove.setAttribute("aria-label", "Remove skill");
    remove.textContent = "×";
    chip.appendChild(remove);

    return chip;
  },

  // ---- description popover ----

  // The popover waits out a full second of hover — a cursor passing through
  // (or briefly aiming for the ×) shouldn't flash it. Inner mouseover events
  // (label span, × button) must not restart the countdown.
  schedulePopover(chip) {
    if (this.popoverTimerChip === chip || this.popoverChip === chip) return;
    clearTimeout(this.popoverTimer);
    this.popoverTimerChip = chip;
    this.popoverTimer = setTimeout(() => {
      this.popoverTimerChip = null;
      if (chip.isConnected) this.showPopover(chip);
    }, 1000);
  },

  showPopover(chip) {
    this.popoverChip = chip;
    const skill = this.skills.find((s) => s.location === chip.dataset.location);

    this.popover.replaceChildren();
    const name = document.createElement("div");
    name.className = "text-[13px] font-medium text-neutral-900";
    name.textContent = skill?.name || chip.dataset.name;
    this.popover.appendChild(name);
    if (skill?.description) {
      const description = document.createElement("div");
      description.className = "mt-1 text-xs leading-5 text-neutral-500";
      description.textContent = skill.description;
      this.popover.appendChild(description);
    }

    this.popover.hidden = false;
    const chipRect = chip.getBoundingClientRect();
    const rect = this.popover.getBoundingClientRect();
    const left = Math.max(
      8,
      Math.min(chipRect.left, window.innerWidth - rect.width - 8),
    );
    let top = chipRect.top - rect.height - 8;
    if (top < 8) top = chipRect.bottom + 8;
    this.popover.style.left = `${left}px`;
    this.popover.style.top = `${top}px`;
  },

  hidePopover() {
    clearTimeout(this.popoverTimer);
    this.popoverTimerChip = null;
    this.popover.hidden = true;
    this.popoverChip = null;
  },
};
