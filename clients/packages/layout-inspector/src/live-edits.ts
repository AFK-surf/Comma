import {
  isVariableRelevantToProperty,
  type AuthoredLayoutValue,
  type InspectedLayoutProperty,
} from "./authored-values";
import {
  formatLayoutSourceLocation,
  layoutInspectorSourceAttribute,
  parseLayoutSourceLocation,
  type LayoutSourceLocation,
} from "./source-location";

export type LayoutVariableOption = {
  label: string;
  value: string;
};

export type LayoutVariableContext = {
  authoredValue: AuthoredLayoutValue;
  element: Element;
  property: InspectedLayoutProperty;
};

export type ResolveLayoutVariables = (
  context: LayoutVariableContext
) => readonly LayoutVariableOption[];

export type LayoutElementTarget = {
  ancestorContext: string[];
  classNames: string[];
  omittedRuntimeIds: boolean;
  position: string;
  selector: string;
  selectorKind: "class-set" | "stable-attribute" | "stable-id" | "structural";
  sourceLocation?: LayoutSourceLocation;
  stableAttributes: string[];
  tagName: string;
};

export type PendingLayoutChange = {
  afterComputed: string;
  afterVariable: string;
  beforeComputed: string;
  beforeConfidence?: AuthoredLayoutValue["confidence"];
  beforeExpression: string;
  beforeVariables?: string[];
  elementKey: string;
  id: string;
  nodeLabel: string;
  property: InspectedLayoutProperty;
  sourceSelector?: string;
  target: LayoutElementTarget;
};

export function variableOptionsForProperty(
  property: InspectedLayoutProperty,
  authoredValue: AuthoredLayoutValue,
  element: Element
): LayoutVariableOption[] {
  const computedStyle = getComputedStyle(element);
  const variables = new Set(
    Array.from(computedStyle).filter(
      (name) => name.startsWith("--") && isVariableRelevantToProperty(name, property)
    )
  );
  for (const variable of authoredValue.variables) variables.add(variable);

  return Array.from(variables)
    .map((variable) => ({
      resolved: computedStyle.getPropertyValue(variable).trim(),
      value: variable,
    }))
    .toSorted(compareVariableOptions)
    .map(({ resolved, value }) => ({
      label: resolved ? `${value} · ${resolved}` : `${value} · current`,
      value,
    }));
}

function compareVariableOptions(
  left: { resolved: string; value: string },
  right: { resolved: string; value: string }
) {
  const leftPixels = pixelValue(left.resolved);
  const rightPixels = pixelValue(right.resolved);
  if (leftPixels !== undefined && rightPixels !== undefined) {
    const difference = leftPixels - rightPixels;
    if (difference !== 0) return difference;
  }
  return left.value.localeCompare(right.value);
}

function pixelValue(value: string) {
  const match = /^(-?\d*\.?\d+)px$/.exec(value.trim());
  if (!match?.[1]) return undefined;
  const parsed = Number.parseFloat(match[1]);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function createElementSelector(element: Element): string {
  return createSelectorCandidate(element).selector;
}

export function describeElementTarget(element: Element): LayoutElementTarget {
  const selectorCandidate = createSelectorCandidate(element);
  const sourceLocation = parseLayoutSourceLocation(
    element.getAttribute(layoutInspectorSourceAttribute)
  );
  const ancestorContext: string[] = [];
  let omittedRuntimeIds = isLikelyRuntimeId(element.id);
  let ancestor = element.parentElement;

  while (ancestor && ancestor !== document.body && ancestorContext.length < 2) {
    ancestorContext.push(describeContextElement(ancestor));
    omittedRuntimeIds ||= isLikelyRuntimeId(ancestor.id);
    ancestor = ancestor.parentElement;
  }

  return {
    ancestorContext,
    classNames: inspectableClassNames(element),
    omittedRuntimeIds,
    position: describeSiblingPosition(element),
    selector: selectorCandidate.selector,
    selectorKind: selectorCandidate.kind,
    ...(sourceLocation ? { sourceLocation } : {}),
    stableAttributes: stableAttributeDescriptions(element),
    tagName: element.tagName.toLowerCase(),
  };
}

export function buildElementSourceReport(element: Element) {
  const target = describeElementTarget(element);
  return [
    "Layout Inspector · selected element source",
    "",
    ...describeTargetLines(target),
    ...(!target.sourceLocation
      ? [
          "- Source location unavailable: no source metadata on this element. Use the locator and source-search hints above.",
        ]
      : []),
  ].join("\n");
}

function describeTargetLines(target: LayoutElementTarget): string[] {
  const lines: string[] = [];
  if (target.sourceLocation) {
    lines.push(
      `- Source location: ${inlineCode(
        formatLayoutSourceLocation(target.sourceLocation)
      )}`
    );
  }
  lines.push(`- Element: <${target.tagName}>`);
  lines.push(`- Best-effort runtime locator: ${inlineCode(target.selector)}`);
  if (target.stableAttributes.length > 0) {
    lines.push(
      `- Stable attributes: ${target.stableAttributes
        .map((attribute) => inlineCode(attribute))
        .join(", ")}`
    );
  }
  if (target.classNames.length > 0) {
    lines.push(
      `- Classes (source-search hint): ${inlineCode(target.classNames.join(" "))}`
    );
  }
  if (target.ancestorContext.length > 0 || target.position) {
    lines.push("- DOM context:");
    target.ancestorContext.forEach((context, index) => {
      lines.push(`  - ${index === 0 ? "parent" : `ancestor ${index + 1}`}: ${context}`);
    });
    lines.push(`  - sibling position: ${target.position}`);
  }
  if (target.omittedRuntimeIds) {
    lines.push(
      "- Runtime-generated IDs were intentionally omitted because they are unstable between renders."
    );
  }
  return lines;
}

export function buildPendingChangesPrompt(changes: PendingLayoutChange[]) {
  const groupedChanges = new Map<string, PendingLayoutChange[]>();
  for (const change of changes) {
    const existing = groupedChanges.get(change.elementKey);
    if (existing) existing.push(change);
    else groupedChanges.set(change.elementKey, [change]);
  }

  const lines: string[] = [
    "Please apply these Layout Inspector changes in the owning source components or styles.",
    "The inspector used temporary runtime inline styles for preview only; do not keep or reproduce those inline styles.",
    "",
  ];

  let targetIndex = 0;
  for (const targetChanges of groupedChanges.values()) {
    const firstChange = targetChanges[0];
    if (!firstChange) continue;
    targetIndex += 1;

    const { target } = firstChange;
    lines.push(`Target ${targetIndex}`);
    lines.push(...describeTargetLines(target));

    const sourceSelectors = Array.from(
      new Set(
        targetChanges
          .map((change) => change.sourceSelector)
          .filter((selector): selector is string => Boolean(selector))
      )
    );
    if (sourceSelectors.length > 0) {
      lines.push(
        `- Matched runtime CSS rule${sourceSelectors.length > 1 ? "s" : ""} (lookup ${
          sourceSelectors.length > 1 ? "clues" : "clue"
        }, not source ownership): ${sourceSelectors
          .map((selector) => inlineCode(selector))
          .join(", ")}`
      );
    }

    lines.push("- Requested source change:");
    for (const change of targetChanges) {
      lines.push(
        `  - ${change.property}: ${change.beforeExpression} [${change.beforeComputed}] → var(${change.afterVariable}) [${change.afterComputed}]`
      );
    }

    lines.push("- Source-edit guidance:");
    if (target.sourceLocation) {
      lines.push(
        `  - Open ${inlineCode(
          formatLayoutSourceLocation(target.sourceLocation)
        )} first and update the element declared there.`
      );
      if (target.classNames.length > 0) {
        lines.push(
          `  - If that location moved, search for the exact class sequence ${inlineCode(
            target.classNames.join(" ")
          )} and use the stable attributes and DOM context above as fallback evidence.`
        );
      }
    } else if (target.classNames.length > 0) {
      lines.push(
        `  - Search the owning JSX/template for the exact class sequence ${inlineCode(
          target.classNames.join(" ")
        )}; if classes are composed, use the stable attributes and DOM context above.`
      );
    } else if (target.stableAttributes.length > 0) {
      lines.push(
        "  - Use the stable attributes and DOM context above to locate the owning JSX/template."
      );
    } else {
      lines.push(
        "  - Use the runtime locator and DOM context above to locate the owning JSX/template."
      );
    }

    const utilitySelectors = sourceSelectors.filter((selector) =>
      targetChanges.some((change) =>
        isLikelyLayoutUtilitySelector(selector, change.property)
      )
    );
    if (utilitySelectors.length > 0) {
      lines.push(
        `  - ${utilitySelectors.map((selector) => inlineCode(selector)).join(", ")} ${
          utilitySelectors.length > 1 ? "look" : "looks"
        } like ${
          utilitySelectors.length > 1
            ? "shared layout utilities"
            : "a shared layout utility"
        }. Change the utility/class used by this element; do not edit the global utility definition for a one-element change.`
      );
    }
    lines.push(
      "  - Do not change a shared custom-property value solely to implement a local edit; update a design token only when the intended scope is global."
    );
    lines.push("");
  }

  lines.push("Preserve unrelated styles and update the relevant tests.");
  return lines.join("\n");
}

function createSelectorCandidate(element: Element): {
  kind: LayoutElementTarget["selectorKind"];
  selector: string;
} {
  for (const { selector } of stableAttributeSelectors(element)) {
    if (isUniqueSelector(selector, element)) {
      return { kind: "stable-attribute", selector };
    }
  }

  if (element.id && !isLikelyRuntimeId(element.id)) {
    const selector = `#${escapeCssIdentifier(element.id)}`;
    if (isUniqueSelector(selector, element)) {
      return { kind: "stable-id", selector };
    }
  }

  const classSelector = selectorForClassSet(element);
  if (classSelector && isUniqueSelector(classSelector, element)) {
    return { kind: "class-set", selector: classSelector };
  }

  return {
    kind: "structural",
    selector: createStructuralSelector(element),
  };
}

function createStructuralSelector(element: Element): string {
  const tagName = element.tagName.toLowerCase();
  const parent = element.parentElement;
  if (!parent) return tagName;

  const directParent = parent === document.body ? undefined : directSelector(parent);
  const parentSelector =
    parent === document.body
      ? "body"
      : (directParent?.selector ?? createStructuralSelector(parent));
  const classSelector = selectorForClassSet(element);
  if (classSelector) {
    const contextualSelector = `${parentSelector} > ${classSelector}`;
    if (isUniqueSelector(contextualSelector, element)) return contextualSelector;
  }

  const siblings = Array.from(parent.children).filter(
    (sibling) => sibling.tagName === element.tagName
  );
  const position = Math.max(siblings.indexOf(element) + 1, 1);
  return `${parentSelector} > ${tagName}:nth-of-type(${position})`;
}

function directSelector(element: Element) {
  for (const { selector } of stableAttributeSelectors(element)) {
    if (isUniqueSelector(selector, element)) return { selector };
  }

  if (element.id && !isLikelyRuntimeId(element.id)) {
    const selector = `#${escapeCssIdentifier(element.id)}`;
    if (isUniqueSelector(selector, element)) return { selector };
  }

  const classSelector = selectorForClassSet(element);
  if (classSelector && isUniqueSelector(classSelector, element)) {
    return { selector: classSelector };
  }
  return undefined;
}

function stableAttributeSelectors(element: Element) {
  const attributes = [
    "data-testid",
    "data-test",
    "data-slot",
    "data-component",
    "aria-label",
    "name",
  ];
  for (const attribute of Array.from(element.attributes)) {
    if (
      attribute.name.startsWith("data-comma-") &&
      attribute.name !== layoutInspectorSourceAttribute &&
      !attribute.name.startsWith("data-comma-layout-inspector")
    ) {
      attributes.push(attribute.name);
    }
  }

  return Array.from(new Set(attributes)).flatMap((attribute) => {
    const value = element.getAttribute(attribute);
    if (!value) return [];
    return [
      {
        attribute,
        selector: `[${attribute}="${escapeCssString(value)}"]`,
        value,
      },
    ];
  });
}

function stableAttributeDescriptions(element: Element) {
  const attributes = stableAttributeSelectors(element).map(
    ({ attribute, value }) => `${attribute}="${value}"`
  );
  if (element.id && !isLikelyRuntimeId(element.id)) {
    attributes.unshift(`id="${element.id}"`);
  }
  return attributes;
}

function selectorForClassSet(element: Element) {
  const classNames = inspectableClassNames(element);
  if (classNames.length === 0) return undefined;
  return `${element.tagName.toLowerCase()}${classNames
    .map((className) => `.${escapeCssIdentifier(className)}`)
    .join("")}`;
}

function inspectableClassNames(element: Element) {
  return Array.from(element.classList).filter(
    (className) => !className.startsWith("comma-layout-inspector")
  );
}

function describeContextElement(element: Element) {
  const attributes = stableAttributeDescriptions(element);
  const classNames = inspectableClassNames(element);
  const details = [
    ...attributes.map((attribute) => inlineCode(attribute)),
    ...(classNames.length > 0 ? [inlineCode(`class="${classNames.join(" ")}"`)] : []),
  ];
  const runtimeIdNote = isLikelyRuntimeId(element.id)
    ? " (runtime-generated id omitted)"
    : "";
  return `<${element.tagName.toLowerCase()}>${
    details.length > 0 ? ` ${details.join(" ")}` : ""
  }${runtimeIdNote}`;
}

function describeSiblingPosition(element: Element) {
  const parent = element.parentElement;
  if (!parent) return "no parent";
  const sameTagSiblings = Array.from(parent.children).filter(
    (sibling) => sibling.tagName === element.tagName
  );
  const position = Math.max(sameTagSiblings.indexOf(element) + 1, 1);
  return `${position} of ${sameTagSiblings.length} <${element.tagName.toLowerCase()}> children`;
}

function isLikelyRuntimeId(id: string) {
  const value = id.trim();
  if (!value) return false;
  if (/^[:«*]r(?:[_:-]?[a-z0-9]+)+[:»*]$/i.test(value)) return true;
  return /^(?:radix|react-aria)-/i.test(value) && /[:«*]r[_:-]?[a-z0-9]+/i.test(value);
}

function isLikelyLayoutUtilitySelector(
  selector: string,
  property: InspectedLayoutProperty
) {
  const match = /^\.([a-zA-Z_][\w-]*)$/.exec(selector.trim());
  const className = match?.[1];
  if (!className) return false;

  if (property === "column-gap" || property === "row-gap") {
    return /^gap(?:-[xy])?-/.test(className);
  }
  if (property.startsWith("margin-")) return /^-?m[trblxy]?-/.test(className);
  if (property.startsWith("padding-")) return /^p[trblxy]?-/.test(className);
  if (property.startsWith("border-")) return /^border(?:-[trblxy])?-/.test(className);
  if (property === "width") return /^(?:w|min-w|max-w)-/.test(className);
  if (property === "height") return /^(?:h|min-h|max-h)-/.test(className);
  return false;
}

function inlineCode(value: string) {
  return `\`${value.replaceAll("`", "\\`")}\``;
}

function isUniqueSelector(selector: string, element: Element) {
  try {
    const matches = document.querySelectorAll(selector);
    return matches.length === 1 && matches[0] === element;
  } catch {
    return false;
  }
}

function escapeCssIdentifier(value: string) {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
    return CSS.escape(value);
  }
  return value.replaceAll(/[^a-zA-Z0-9_-]/g, (character) => `\\${character}`);
}

function escapeCssString(value: string) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}
