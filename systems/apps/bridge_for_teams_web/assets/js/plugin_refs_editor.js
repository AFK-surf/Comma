const REF_KEYS = [
  "tool_refs",
  "skill_refs",
  "mcp_refs",
  "oauth_requirements",
  "im_connect_requirements",
];

const emptyRefs = () => Object.fromEntries(REF_KEYS.map((key) => [key, []]));

const normalizedRefs = (value) => {
  const refs = emptyRefs();

  if (!value || typeof value !== "object" || Array.isArray(value)) return refs;

  for (const key of REF_KEYS) {
    refs[key] = Array.isArray(value[key]) ? value[key] : [];
  }

  return refs;
};

const entryKey = (entry) => JSON.stringify(entry);

const entryLabel = (entry) => {
  if (typeof entry === "string") return entry;
  if (entry && typeof entry === "object") {
    return (
      entry.tool_id ||
      entry.skill_id ||
      entry.mcp_id ||
      entry.provider ||
      JSON.stringify(entry)
    );
  }
  return String(entry);
};

const parseEntry = (raw) => {
  const value = raw.trim();
  if (!value) return null;
  if (!value.startsWith("{")) return value;

  const parsed = JSON.parse(value);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("object_ref");
  }

  return parsed;
};

export const PluginRefsEditor = {
  mounted() {
    this.output = this.el.querySelector("[data-plugin-refs-output]");
    this.advanced = this.el.querySelector("[data-plugin-refs-json]");
    this.error = this.el.querySelector("[data-plugin-refs-error]");
    this.objectRefError = this.el.dataset.errorObjectRef;
    this.invalidJsonError = this.el.dataset.errorInvalidJson;
    this.refsObjectError = this.el.dataset.errorRefsObject;
    this.arrayError = this.el.dataset.errorArray;
    this.removeLabel = this.el.dataset.removeLabel;
    this.groups = [...this.el.querySelectorAll("[data-plugin-ref-group]")];
    this.refs = this.readInitialRefs();

    this.groups.forEach((group) => this.bindGroup(group));
    this.advanced?.addEventListener("input", () => this.readAdvanced());
    this.el.closest("form")?.addEventListener("submit", (event) => {
      this.groups.forEach((group) => this.commitInput(group, false));
      if (!this.readAdvanced()) event.preventDefault();
    });

    this.renderGroups();
    this.sync(true);
  },

  readInitialRefs() {
    try {
      return normalizedRefs(JSON.parse(this.el.dataset.refs || "{}"));
    } catch (_error) {
      return emptyRefs();
    }
  },

  bindGroup(group) {
    const input = group.querySelector("[data-plugin-ref-input]");
    const chips = group.querySelector("[data-plugin-ref-chips]");

    input?.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.isComposing) return;
      event.preventDefault();
      this.commitInput(group, true);
    });

    input?.addEventListener("blur", () => this.commitInput(group, false));
    group
      .querySelector("[data-plugin-ref-add]")
      ?.addEventListener("click", () => this.commitInput(group, true));

    chips?.addEventListener("click", (event) => {
      const remove = event.target.closest("[data-plugin-ref-remove]");
      if (!remove || !chips.contains(remove)) return;

      const key = group.dataset.pluginRefGroup;
      const index = Number(remove.dataset.pluginRefRemove);
      if (!Number.isInteger(index) || index < 0) return;

      this.refs[key].splice(index, 1);
      this.renderGroup(group);
      this.sync(true);
    });
  },

  commitInput(group, report) {
    const key = group.dataset.pluginRefGroup;
    const input = group.querySelector("[data-plugin-ref-input]");
    if (!input?.value.trim()) return true;

    try {
      const entry = parseEntry(input.value);
      const duplicate = this.refs[key].some(
        (item) => entryKey(item) === entryKey(entry),
      );
      if (!duplicate) this.refs[key].push(entry);

      input.value = "";
      input.setCustomValidity("");
      input.removeAttribute("aria-invalid");
      this.renderGroup(group);
      this.sync(true);
      return true;
    } catch (_error) {
      const message = this.objectRefError;
      input.setCustomValidity(message);
      input.setAttribute("aria-invalid", "true");
      if (report) input.reportValidity();
      return false;
    }
  },

  readAdvanced() {
    if (!this.advanced) return true;

    try {
      const parsed = JSON.parse(this.advanced.value || "{}");
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error(this.refsObjectError);
      }

      for (const key of REF_KEYS) {
        if (parsed[key] != null && !Array.isArray(parsed[key])) {
          throw new Error(this.arrayError);
        }
      }

      this.refs = normalizedRefs(parsed);
      this.advanced.setCustomValidity("");
      this.advanced.removeAttribute("aria-invalid");
      this.setError("");
      this.renderGroups();
      this.sync(false);
      return true;
    } catch (error) {
      const message =
        error instanceof SyntaxError ? this.invalidJsonError : error.message;
      this.advanced.setCustomValidity(message);
      this.advanced.setAttribute("aria-invalid", "true");
      this.setError(message);
      return false;
    }
  },

  renderGroups() {
    this.groups.forEach((group) => this.renderGroup(group));
  },

  renderGroup(group) {
    const key = group.dataset.pluginRefGroup;
    const chips = group.querySelector("[data-plugin-ref-chips]");
    if (!chips) return;

    chips.replaceChildren();

    this.refs[key].forEach((entry, index) => {
      const chip = document.createElement("span");
      chip.className =
        "inline-flex max-w-full items-center gap-1 rounded-md border border-neutral-200 bg-neutral-50 px-2 py-1 text-xs text-neutral-700";

      const label = document.createElement("span");
      label.className = "truncate";
      label.textContent = entryLabel(entry);
      label.title = typeof entry === "string" ? entry : JSON.stringify(entry);

      const remove = document.createElement("button");
      remove.type = "button";
      remove.className =
        "grid h-6 w-6 shrink-0 place-items-center rounded text-neutral-400 hover:bg-neutral-200 hover:text-neutral-800";
      remove.dataset.pluginRefRemove = String(index);
      remove.setAttribute(
        "aria-label",
        `${this.removeLabel} ${entryLabel(entry)}`,
      );
      remove.textContent = "x";

      chip.append(label, remove);
      chips.append(chip);
    });
  },

  sync(updateAdvanced) {
    const json = JSON.stringify(this.refs, null, 2);
    if (this.output) this.output.value = json;
    if (updateAdvanced && this.advanced) this.advanced.value = json;
    this.setError("");
  },

  setError(message) {
    if (!this.error) return;
    this.error.textContent = message;
    this.error.classList.toggle("hidden", !message);
  },
};
