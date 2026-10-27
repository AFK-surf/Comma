import { transform } from "lightningcss";

export function foundationCheckId(name) {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function formatFoundationCheckList(results) {
  return results.map((result) => ({
    ...(result.error ? { error: result.error } : {}),
    id: result.id,
    name: result.name,
    status: result.status,
  }));
}

export function findNativeSessionAdmissionViolations(capabilities) {
  const validAdmissions = new Set(["lifecycle", "required", "local_only"]);
  const violations = [];

  for (const capability of capabilities) {
    if (!validAdmissions.has(capability.sessionAdmission)) {
      violations.push(
        `${capability.id} has invalid sessionAdmission ${String(
          capability.sessionAdmission
        )}`
      );
      continue;
    }

    const rationale = capability.sessionAdmissionRationale?.trim();
    if (capability.sessionAdmission === "local_only" && !rationale) {
      violations.push(`${capability.id} local_only is missing a rationale`);
    }
    if (capability.sessionAdmission !== "local_only" && rationale) {
      violations.push(
        `${capability.id} declares a local-only rationale with ${capability.sessionAdmission}`
      );
    }
  }

  return violations;
}

/**
 * Looping animations that would move on every display refresh: an `animation`
 * (CSS, or a style object's) or a Web Animation that repeats forever without
 * `steps()` or a `--motion-loop-*` timing function. A 240 Hz display redraws
 * such a loop four times as often as a 60 Hz one, for motion that looks the
 * same. A paused loop passes; so does one whose declaration says why it may
 * not be capped, in a `motion-loop: exempt <reason>` comment. Each finding is
 * `line N: <declaration>`.
 */
export function findUncappedLoops(source) {
  const found = [];
  let offset = 0;
  // Declarations end at `;`, `{` or `}`; a style object's entries and a
  // Web Animation's options sit in one such stretch too.
  for (const stretch of source.split(/(?<=[;{}])/)) {
    const start = offset;
    offset += stretch.length;
    const code = stretch.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    const loops =
      /\banimation\s*:[^;{}]*\binfinite\b/i.test(code) ||
      /\banimation-iteration-count\s*:\s*infinite\b/i.test(code) ||
      /\banimationIterationCount\s*:\s*["'`]infinite/.test(code) ||
      /\biterations\s*:\s*Infinity\b/.test(code);
    if (!loops) continue;
    if (/steps\(|--motion-loop-|\bpaused\b/.test(code)) continue;
    if (/motion-loop:\s*exempt\s+\S/.test(stretch)) continue;
    const line =
      source.slice(0, start).split("\n").length +
      (stretch.match(/^\s*/)?.[0].split("\n").length ?? 1) -
      1;
    found.push(
      `line ${line}: ${code
        .trim()
        .replace(/\s+/g, " ")
        .replace(/[;{}]$/, "")}`
    );
  }
  return found;
}

/**
 * Style rules whose subject is universal (`*`, or a compound without a type,
 * class, id or attribute) while a compound left of it holds a `:has()`, as in
 * `.a:has(.b) *` or `:is(.a:has(.b)) { &, & * {} }`. Chromium keeps one
 * invalidation set for every `:has()` in a non-subject position, so one such
 * rule makes it restyle the whole subtree of each `:has()` anchor whenever a
 * node is inserted under it. Nesting is resolved first.
 *
 * What lightningcss cannot read is reported too, so nothing passes unchecked:
 * its parse errors, and Tailwind blocks (kept as raw tokens) that hold a
 * `:has()`. Tailwind's own at-rules are otherwise expected.
 */
export function findHasBeforeUniversalSubjects(css, filename = "styles.css") {
  const found = [];
  // Lower nesting so each rule carries its whole selector, then walk them.
  const lowered = transform({
    filename,
    code: Buffer.from(css),
    errorRecovery: true,
    targets: { chrome: 100 << 16 },
    visitor: {
      Rule: {
        unknown(rule) {
          if (holdsHasToken([rule.prelude, rule.block]))
            found.push(
              `line ${rule.loc.line + 1}: @${rule.name} holds a :has() this check cannot see; move it to a plain style rule`
            );
        },
      },
    },
  });
  for (const warning of lowered.warnings)
    if (!(warning.type === "AtRuleInvalid" && tailwindAtRules.has(warning.value)))
      found.push(
        `line ${warning.loc.line}: lightningcss could not parse this (${warning.message}), so this check cannot see its selectors`
      );
  const flat = lowered.code;
  const lines = flat.toString().split("\n");
  // The rule's whole selector list, which may span lines, up to its block.
  const selectorAt = ({ line, column }) => {
    const rest = lines
      .slice(line)
      .join(" ")
      .slice(column - 1);
    return rest.slice(0, rest.indexOf("{")).replace(/\s+/g, " ").trim();
  };
  transform({
    filename,
    code: flat,
    errorRecovery: true,
    visitor: {
      Rule: {
        style(rule) {
          if (rule.value.selectors.some(subjectFollowsHas))
            found.push(selectorAt(rule.value.loc));
        },
      },
    },
  });
  return found;
}

const tailwindAtRules = new Set([
  "theme",
  "utility",
  "variant",
  "custom-variant",
  "source",
  "apply",
  "reference",
  "config",
  "plugin",
  "tailwind",
]);

// An unparsed at-rule's prelude and block are token lists; `:has(` is a
// function token named `has`, possibly nested in other tokens' arguments.
function holdsHasToken(value) {
  if (Array.isArray(value)) return value.some(holdsHasToken);
  if (!value || typeof value !== "object") return false;
  if (value.type === "function" && value.value?.name?.toLowerCase() === "has")
    return true;
  return Object.values(value).some(holdsHasToken);
}

function subjectFollowsHas(selector) {
  const compounds = [[]];
  for (const component of selector)
    if (component.type === "combinator") compounds.push([]);
    else compounds.at(-1).push(component);
  const subject = compounds.pop();
  if (compounds.some((compound) => compound.some(holdsHas)) && !hasFeature(subject))
    return true;
  // The selectors in a subject `:is()`, `:where()` or `:not()` are subjects too.
  return subject.some(
    (component) =>
      ["is", "where", "not"].includes(component.kind) &&
      component.selectors.some(subjectFollowsHas)
  );
}

function holdsHas(component) {
  return (
    component.kind === "has" ||
    (component.selectors ?? []).some((selector) => selector.some(holdsHas))
  );
}

function hasFeature(compound) {
  return compound.some(
    (component) =>
      ["type", "class", "id", "attribute"].includes(component.type) ||
      (["is", "where"].includes(component.kind) &&
        component.selectors.every((selector) =>
          hasFeature(selector.slice(selector.findLastIndex(isCombinator) + 1))
        ))
  );
}

function isCombinator(component) {
  return component.type === "combinator";
}
