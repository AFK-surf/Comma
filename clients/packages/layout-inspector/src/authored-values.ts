export const inspectedLayoutProperties = [
  "width",
  "height",
  "margin-top",
  "margin-right",
  "margin-bottom",
  "margin-left",
  "border-top-width",
  "border-right-width",
  "border-bottom-width",
  "border-left-width",
  "padding-top",
  "padding-right",
  "padding-bottom",
  "padding-left",
  "row-gap",
  "column-gap",
] as const;

export type InspectedLayoutProperty = (typeof inspectedLayoutProperties)[number];

export type AuthoredLayoutValue = {
  computed: string;
  confidence: "authored" | "computed" | "inferred";
  expression?: string;
  selector?: string;
  variables: string[];
};

export type AuthoredLayoutValues = Record<InspectedLayoutProperty, AuthoredLayoutValue>;

type DeclarationExpression = {
  expression: string;
  sourceProperty: string;
};

type DeclarationCandidate = DeclarationExpression & {
  inline: boolean;
  selector?: string;
};

type DeclarationCollection = {
  ambiguousExpressions: Record<InspectedLayoutProperty, DeclarationExpression[]>;
  candidates: Record<InspectedLayoutProperty, DeclarationCandidate[]>;
  hasOpaqueStyleSheet: boolean;
};

type ScopeContext = {
  end: string | null;
  implicitRoot: Document | Element | ShadowRoot | null;
  start: string | null;
};

type DeclarationRule = {
  selectorText?: string;
  style: CSSStyleDeclaration;
};

type RuleContext = {
  activity: "active" | "unknown";
  selectorMatching: "normal" | "unknown";
  scopes: readonly ScopeContext[];
};
type RuleActivity = RuleContext["activity"] | "inactive";

const variablePattern = /var\(\s*(--[\w-]+)/g;
const pixelTolerance = 0.05;
const maxStyleSheetRootContexts = 32;

export function resolveAuthoredLayoutValues(element: Element): AuthoredLayoutValues {
  const computedStyle = getComputedStyle(element);
  const probe = createExpressionProbe(computedStyle);
  const declarationCollection = collectDeclarationCandidates({
    computedStyle,
    element,
  });

  try {
    return Object.fromEntries(
      inspectedLayoutProperties.map((property) => [
        property,
        resolvePropertyValue({
          ambiguousExpressions: declarationCollection.ambiguousExpressions[property],
          candidates: declarationCollection.candidates[property],
          computed: computedStyle.getPropertyValue(property).trim(),
          computedStyle,
          element,
          hasOpaqueStyleSheet: declarationCollection.hasOpaqueStyleSheet,
          probe,
          property,
        }),
      ])
    ) as AuthoredLayoutValues;
  } finally {
    probe?.remove();
  }
}

function resolvePropertyValue({
  ambiguousExpressions,
  candidates,
  computed,
  computedStyle,
  element,
  hasOpaqueStyleSheet,
  probe,
  property,
}: {
  ambiguousExpressions: readonly DeclarationExpression[];
  candidates: readonly DeclarationCandidate[];
  computed: string;
  computedStyle: CSSStyleDeclaration;
  element: Element;
  hasOpaqueStyleSheet: boolean;
  probe: HTMLElement | null;
  property: InspectedLayoutProperty;
}): AuthoredLayoutValue {
  const allCandidates = candidates;
  const hasUnknownCompetitor =
    hasOpaqueStyleSheet ||
    animationsAffectProperty(element, property) ||
    uniqueDeclarationExpressions(ambiguousExpressions).length > 0;
  const evaluatedCandidates = allCandidates.map((candidate) => ({
    candidate,
    matches: expressionMatchesComputedValue({
      computed,
      computedStyle,
      expression: candidate.expression,
      property,
      probe,
      sourceProperty: candidate.sourceProperty,
    }),
  }));
  const soleCandidate = hasUnknownCompetitor
    ? undefined
    : singleCandidate(allCandidates);
  const soleCandidateMatches =
    evaluatedCandidates.length === 1 ? evaluatedCandidates[0]?.matches : undefined;
  const candidateVariables = soleCandidate
    ? extractVariables(soleCandidate.expression)
    : [];
  const variablesResolve =
    candidateVariables.length > 0 &&
    candidateVariables.every(
      (variable) => computedStyle.getPropertyValue(variable).trim().length > 0
    );
  const sourceValueIsValid =
    soleCandidate && declarationExpressionIsSafelyValid(soleCandidate, computedStyle);
  const soleAuthored =
    soleCandidate &&
    variablesResolve &&
    sourceValueIsValid &&
    (soleCandidate.inline || soleCandidateMatches === true)
      ? soleCandidate
      : undefined;
  const authored =
    soleAuthored ??
    (!hasUnknownCompetitor
      ? safeFixedSpacingWinner(evaluatedCandidates, property, computedStyle)
      : undefined);

  if (authored) {
    return {
      computed,
      confidence: "authored",
      expression: authored.expression,
      ...(authored.selector ? { selector: authored.selector } : {}),
      variables: extractVariables(authored.expression),
    };
  }

  // A detached probe cannot reproduce unknown cascade or layout dependencies.
  // Inference remains best-effort and is disabled as soon as any known
  // declaration cannot be evaluated safely.
  const canInfer =
    !hasUnknownCompetitor &&
    evaluatedCandidates.every(({ matches }) => matches !== undefined);
  const inferred = canInfer ? inferToken(property, computed, computedStyle) : undefined;
  if (inferred) {
    return {
      computed,
      confidence: "inferred",
      variables: [inferred],
    };
  }

  return {
    computed,
    confidence: "computed",
    variables: [],
  };
}

function animationsAffectProperty(element: Element, property: InspectedLayoutProperty) {
  if (typeof element.getAnimations !== "function") return false;

  const propertyNames = animationPropertyNames(property);
  for (const animation of element.getAnimations()) {
    const effect = animation.effect;
    if (typeof KeyframeEffect === "undefined" || !(effect instanceof KeyframeEffect)) {
      return true;
    }
    if (effect.target !== element) continue;

    let keyframes: ReturnType<KeyframeEffect["getKeyframes"]>;
    try {
      keyframes = effect.getKeyframes();
    } catch {
      return true;
    }
    if (
      keyframes.some((keyframe) =>
        Object.keys(keyframe).some((key) => propertyNames.has(key))
      )
    ) {
      return true;
    }
  }
  return false;
}

function animationPropertyNames(property: InspectedLayoutProperty) {
  const names = new Set([property, camelCaseProperty(property)]);
  if (property.startsWith("margin-")) {
    for (const name of [
      "margin",
      "margin-block",
      "margin-block-end",
      "margin-block-start",
      "margin-inline",
      "margin-inline-end",
      "margin-inline-start",
    ]) {
      names.add(name);
      names.add(camelCaseProperty(name));
    }
  } else if (property.startsWith("padding-")) {
    for (const name of [
      "padding",
      "padding-block",
      "padding-block-end",
      "padding-block-start",
      "padding-inline",
      "padding-inline-end",
      "padding-inline-start",
    ]) {
      names.add(name);
      names.add(camelCaseProperty(name));
    }
  } else if (property === "row-gap" || property === "column-gap") {
    names.add("gap");
  }
  return names;
}

function camelCaseProperty(property: string) {
  return property.replace(/-([a-z])/g, (_match, letter: string) =>
    letter.toUpperCase()
  );
}

function safeFixedSpacingWinner(
  evaluatedCandidates: ReadonlyArray<{
    candidate: DeclarationCandidate;
    matches: boolean | undefined;
  }>,
  property: InspectedLayoutProperty,
  computedStyle: CSSStyleDeclaration
) {
  if (
    !property.startsWith("margin-") &&
    !property.startsWith("padding-") &&
    property !== "row-gap" &&
    property !== "column-gap"
  ) {
    return undefined;
  }

  const matching = evaluatedCandidates.filter(({ matches }) => matches === true);
  const winner = singleCandidate(matching.map(({ candidate }) => candidate));
  if (
    !winner ||
    extractVariables(winner.expression).length === 0 ||
    !declarationExpressionIsSafelyValid(winner, computedStyle)
  ) {
    return undefined;
  }

  const everyCompetitorIsFixedAndNonmatching = evaluatedCandidates.every(
    ({ candidate, matches }) =>
      candidate === winner ||
      (matches === false &&
        /^-?\d*\.?\d+px$/i.test(
          resolveSimpleDeclarationExpression(candidate.expression, computedStyle) ?? ""
        ))
  );
  return everyCompetitorIsFixedAndNonmatching ? winner : undefined;
}

function collectDeclarationCandidates({
  computedStyle,
  element,
}: {
  computedStyle: CSSStyleDeclaration;
  element: Element;
}) {
  const candidates = {} as Record<InspectedLayoutProperty, DeclarationCandidate[]>;
  const ambiguousExpressions = {} as Record<
    InspectedLayoutProperty,
    DeclarationExpression[]
  >;
  for (const property of inspectedLayoutProperties) {
    ambiguousExpressions[property] = [];
    candidates[property] = [];
  }
  let hasOpaqueStyleSheet = false;

  appendDeclarationCandidates({
    candidates,
    computedStyle,
    declaration: (element as HTMLElement | SVGElement).style,
    inline: true,
  });

  const applicableSheets = applicableStyleSheets(element);
  if (applicableSheets.truncated) hasOpaqueStyleSheet = true;

  for (const { selectorMatching, sheet, treeRoot } of applicableSheets.entries) {
    walkStyleRules(
      sheet,
      treeRoot,
      selectorMatching,
      (rule, context) => {
        const selectorMatch =
          context.selectorMatching === "unknown" || !rule.selectorText
            ? "unknown"
            : matchRuleSelector(element, rule.selectorText, context);
        if (selectorMatch === "does-not-match") return;

        if (context.activity === "unknown" || selectorMatch === "unknown") {
          appendAmbiguousExpressions({
            ambiguousExpressions,
            computedStyle,
            declaration: rule.style,
          });
          return;
        }

        appendDeclarationCandidates({
          candidates,
          computedStyle,
          declaration: rule.style,
          inline: false,
          ...(rule.selectorText ? { selector: rule.selectorText } : {}),
        });
      },
      () => {
        hasOpaqueStyleSheet = true;
      }
    );
  }

  return {
    ambiguousExpressions,
    candidates,
    hasOpaqueStyleSheet,
  } satisfies DeclarationCollection;
}

function appendAmbiguousExpressions({
  ambiguousExpressions,
  computedStyle,
  declaration,
}: {
  ambiguousExpressions: Record<InspectedLayoutProperty, DeclarationExpression[]>;
  computedStyle: CSSStyleDeclaration;
  declaration: CSSStyleDeclaration;
}) {
  for (const property of inspectedLayoutProperties) {
    ambiguousExpressions[property].push(
      ...expressionsForProperty(declaration, property, computedStyle)
    );
  }
}

function appendDeclarationCandidates({
  candidates,
  computedStyle,
  declaration,
  inline,
  selector,
}: {
  candidates: Record<InspectedLayoutProperty, DeclarationCandidate[]>;
  computedStyle: CSSStyleDeclaration;
  declaration: CSSStyleDeclaration;
  inline: boolean;
  selector?: string;
}) {
  for (const property of inspectedLayoutProperties) {
    const expressions = uniqueDeclarationBlockExpressions(
      expressionsForProperty(declaration, property, computedStyle)
    );
    for (const { expression, sourceProperty } of expressions) {
      candidates[property].push({
        expression,
        inline,
        sourceProperty,
        ...(selector ? { selector } : {}),
      });
    }
  }
}

function expressionsForProperty(
  declaration: CSSStyleDeclaration,
  property: InspectedLayoutProperty,
  computedStyle: CSSStyleDeclaration
) {
  const values: DeclarationExpression[] = [];
  const add = (declaredProperty: string, side?: number, sideCount: 1 | 2 | 4 = 4) => {
    const raw = declaration.getPropertyValue(declaredProperty).trim();
    if (!raw) return;
    values.push({
      expression: side === undefined ? raw : pickShorthandValue(raw, side, sideCount),
      sourceProperty: declaredProperty,
    });
  };

  add(property);

  if (property === "width") {
    if (isHorizontalWritingMode(computedStyle)) add("inline-size");
    return values;
  }
  if (property === "height") {
    if (isHorizontalWritingMode(computedStyle)) add("block-size");
    return values;
  }
  if (property === "row-gap") {
    add("gap", 0, 2);
    return values;
  }
  if (property === "column-gap") {
    add("gap", 1, 2);
    return values;
  }

  const side = physicalSide(property);
  if (side === undefined) return values;

  if (property.startsWith("margin-")) {
    add("margin", side);
    addLogicalSideCandidates(add, "margin", side, computedStyle);
    return values;
  }
  if (property.startsWith("padding-")) {
    add("padding", side);
    addLogicalSideCandidates(add, "padding", side, computedStyle);
    return values;
  }
  if (property.startsWith("border-")) {
    add("border-width", side);
    add(`border-${sideName(side)}`);
    add("border");
    addLogicalSideCandidates(add, "border", side, computedStyle, "-width");
  }

  return values;
}

function addLogicalSideCandidates(
  add: (property: string, side?: number, sideCount?: 1 | 2 | 4) => void,
  prefix: "border" | "margin" | "padding",
  physicalSideIndex: number,
  computedStyle: CSSStyleDeclaration,
  suffix = ""
) {
  if (!isHorizontalWritingMode(computedStyle)) return;

  if (physicalSideIndex === 0) {
    add(`${prefix}-block-start${suffix}`);
    add(`${prefix}-block${suffix}`, 0, 2);
    return;
  }
  if (physicalSideIndex === 2) {
    add(`${prefix}-block-end${suffix}`);
    add(`${prefix}-block${suffix}`, 1, 2);
    return;
  }

  const inlineStart = computedStyle.direction !== "rtl" ? 3 : 1;
  const logicalIndex = physicalSideIndex === inlineStart ? 0 : 1;
  add(`${prefix}-inline-${logicalIndex === 0 ? "start" : "end"}${suffix}`);
  add(`${prefix}-inline${suffix}`, logicalIndex, 2);
}

function pickShorthandValue(raw: string, side: number, sideCount: 1 | 2 | 4) {
  const parts = splitTopLevelWhitespace(raw);
  if (parts.length <= 1) return raw;

  if (sideCount === 2) {
    return parts[side] ?? parts[0] ?? raw;
  }

  if (parts.length === 2) {
    return parts[side % 2] ?? raw;
  }
  if (parts.length === 3) {
    return parts[side === 0 ? 0 : side === 2 ? 2 : 1] ?? raw;
  }
  return parts[side] ?? raw;
}

export function splitTopLevelWhitespace(value: string) {
  const parts: string[] = [];
  let current = "";
  let depth = 0;
  let quote: "'" | '"' | undefined;

  for (const character of value) {
    if (quote) {
      current += character;
      if (character === quote) quote = undefined;
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      current += character;
      continue;
    }
    if (character === "(" || character === "[") {
      depth += 1;
      current += character;
      continue;
    }
    if (character === ")" || character === "]") {
      depth = Math.max(0, depth - 1);
      current += character;
      continue;
    }
    if (/\s/.test(character) && depth === 0) {
      if (current) parts.push(current);
      current = "";
      continue;
    }
    current += character;
  }

  if (current) parts.push(current);
  return parts;
}

function applicableStyleSheets(element: Element) {
  const entries: Array<{
    selectorMatching: RuleContext["selectorMatching"];
    sheet: CSSStyleSheet;
    treeRoot: Document | ShadowRoot;
  }> = [];
  const rootModes = new Map<
    Document | ShadowRoot,
    Set<RuleContext["selectorMatching"]>
  >();
  let truncated = false;

  const appendRoot = (
    root: Document | ShadowRoot,
    selectorMatching: RuleContext["selectorMatching"]
  ) => {
    let modes = rootModes.get(root);
    if (!modes) {
      if (rootModes.size >= maxStyleSheetRootContexts) {
        truncated = true;
        return false;
      }
      modes = new Set();
      rootModes.set(root, modes);
    }
    if (modes.has(selectorMatching)) return true;
    modes.add(selectorMatching);

    for (const sheet of styleSheetsForRoot(root)) {
      entries.push({
        selectorMatching,
        sheet,
        treeRoot: root,
      });
    }
    return true;
  };

  const ownRoot = styleTreeRoot(element.getRootNode());
  if (!ownRoot) return { entries, truncated };
  appendRoot(ownRoot, "normal");

  const slotRoot = styleTreeRoot(element.assignedSlot?.getRootNode());
  if (slotRoot) appendRoot(slotRoot, "unknown");

  // :host and :host-context() declarations live inside an open shadow root but
  // style the selected host across that root boundary.
  if (element.shadowRoot) appendRoot(element.shadowRoot, "unknown");

  // A part may be exposed through multiple nested exportparts boundaries. The
  // browser's part-element map is not exposed to script, so every accessible
  // outer stylesheet tree remains a property-local ambiguous competitor.
  if (element.getAttribute("part")?.trim()) {
    let currentRoot: Document | ShadowRoot = ownRoot;
    while (currentRoot instanceof ShadowRoot) {
      const outerRoot = styleTreeRoot(currentRoot.host.getRootNode());
      if (!outerRoot) break;
      if (!appendRoot(outerRoot, "unknown")) break;
      currentRoot = outerRoot;
    }
  }

  return { entries, truncated };
}

function styleTreeRoot(root: Node | null | undefined) {
  return root instanceof Document || root instanceof ShadowRoot ? root : undefined;
}

function styleSheetsForRoot(root: Document | ShadowRoot) {
  if (root instanceof Document) {
    return uniqueStyleSheets([
      ...Array.from(root.styleSheets),
      ...(root.adoptedStyleSheets ?? []),
    ]);
  }

  const embedded = Array.from(
    root.querySelectorAll<HTMLStyleElement | HTMLLinkElement>(
      'style, link[rel~="stylesheet"]'
    )
  )
    .map((owner) => owner.sheet)
    .filter((sheet): sheet is CSSStyleSheet => sheet !== null);
  return uniqueStyleSheets([...embedded, ...(root.adoptedStyleSheets ?? [])]);
}

function uniqueStyleSheets(sheets: CSSStyleSheet[]) {
  return Array.from(new Set(sheets));
}

function walkStyleRules(
  sheet: CSSStyleSheet,
  treeRoot: Document | ShadowRoot,
  selectorMatching: RuleContext["selectorMatching"],
  visit: (rule: DeclarationRule, context: RuleContext) => void,
  onInaccessible: () => void
) {
  const activity = styleSheetActivity(sheet);
  if (activity === "inactive") return;
  const styleScopeRoot = implicitScopeRoot(sheet, treeRoot);
  walkStyleSheet(
    sheet,
    {
      activity,
      selectorMatching,
      scopes: [],
    },
    new Set(),
    onInaccessible,
    styleScopeRoot,
    treeRoot,
    visit
  );
}

function styleSheetActivity(sheet: CSSStyleSheet): RuleActivity {
  try {
    if (sheet.disabled) return "inactive";
  } catch {
    return "unknown";
  }

  let mediaText: string;
  try {
    mediaText = sheet.media.mediaText.trim();
  } catch {
    return "unknown";
  }
  if (!mediaText) return "active";
  if (typeof window.matchMedia !== "function") return "unknown";

  try {
    return window.matchMedia(mediaText).matches ? "active" : "inactive";
  } catch {
    return "unknown";
  }
}

function walkStyleSheet(
  sheet: CSSStyleSheet,
  context: RuleContext,
  visitedSheets: Set<CSSStyleSheet>,
  onInaccessible: () => void,
  styleScopeRoot: Document | Element | ShadowRoot | null,
  treeRoot: Document | ShadowRoot,
  visit: (rule: DeclarationRule, context: RuleContext) => void
) {
  if (visitedSheets.has(sheet)) return;
  visitedSheets.add(sheet);

  let rules: CSSRuleList;
  try {
    rules = sheet.cssRules;
  } catch {
    onInaccessible();
    return;
  }

  walkRules(
    rules,
    context,
    treeRoot,
    visitedSheets,
    onInaccessible,
    styleScopeRoot,
    visit
  );
}

function walkRules(
  rules: CSSRuleList,
  context: RuleContext,
  treeRoot: Document | ShadowRoot,
  visitedSheets: Set<CSSStyleSheet>,
  onInaccessible: () => void,
  styleScopeRoot: Document | Element | ShadowRoot | null,
  visit: (rule: DeclarationRule, context: RuleContext) => void
) {
  for (const rule of Array.from(rules)) {
    if (isImportRule(rule)) {
      const importedSheet = rule.styleSheet;
      if (!importedSheet) {
        onInaccessible();
        continue;
      }

      const activity = importRuleActivity(rule);
      if (activity === "inactive") continue;
      walkStyleSheet(
        importedSheet,
        {
          ...context,
          activity:
            context.activity === "unknown" || activity === "unknown"
              ? "unknown"
              : "active",
        },
        visitedSheets,
        onInaccessible,
        styleScopeRoot,
        treeRoot,
        visit
      );
      continue;
    }

    if (isStyleRule(rule)) {
      visit(rule, context);

      const nested = (rule as CSSStyleRule & { cssRules?: CSSRuleList }).cssRules;
      if (nested && nested.length > 0) {
        walkRules(
          nested,
          {
            ...context,
            selectorMatching: "unknown",
          },
          treeRoot,
          visitedSheets,
          onInaccessible,
          styleScopeRoot,
          visit
        );
      }
      continue;
    }

    if (isNestedDeclarationsRule(rule)) {
      visit(rule, {
        ...context,
        selectorMatching: "unknown",
      });
      continue;
    }

    const nested = (rule as CSSRule & { cssRules?: CSSRuleList }).cssRules;
    if (!nested) continue;

    const activity = conditionalRuleActivity(rule);
    if (activity === "inactive") continue;
    walkRules(
      nested,
      {
        activity:
          context.activity === "unknown" || activity === "unknown"
            ? "unknown"
            : "active",
        selectorMatching: context.selectorMatching,
        scopes: isScopeRule(rule)
          ? [...context.scopes, scopeContext(rule, styleScopeRoot)]
          : context.scopes,
      },
      treeRoot,
      visitedSheets,
      onInaccessible,
      styleScopeRoot,
      visit
    );
  }
}

function isImportRule(rule: CSSRule): rule is CSSImportRule {
  return (
    rule.constructor?.name === "CSSImportRule" &&
    (rule as Partial<CSSImportRule>).styleSheet !== undefined
  );
}

function importRuleActivity(rule: CSSImportRule): RuleActivity {
  const supportsText = (
    rule as CSSImportRule & {
      supportsText?: string | null;
    }
  ).supportsText;
  if (supportsText) return "unknown";

  const mediaText = rule.media?.mediaText.trim();
  if (!mediaText) return "active";
  if (typeof window.matchMedia !== "function") return "unknown";
  return window.matchMedia(mediaText).matches ? "active" : "inactive";
}

function conditionalRuleActivity(rule: CSSRule): RuleActivity {
  const constructorName = rule.constructor?.name;
  const conditionText = (rule as CSSRule & { conditionText?: string }).conditionText;

  if (constructorName === "CSSMediaRule") {
    if (typeof conditionText !== "string" || typeof window.matchMedia !== "function") {
      return "unknown";
    }
    return window.matchMedia(conditionText).matches ? "active" : "inactive";
  }

  if (constructorName === "CSSSupportsRule") {
    if (
      typeof conditionText !== "string" ||
      typeof CSS === "undefined" ||
      typeof CSS.supports !== "function"
    ) {
      return "unknown";
    }
    return CSS.supports(conditionText) ? "active" : "inactive";
  }

  // These groups need element- or lifecycle-specific matching that CSSOM does not
  // expose. Their matching declarations remain ambiguous competitors instead of
  // being discarded and allowing a lower declaration to look uniquely authored.
  if (
    constructorName === "CSSContainerRule" ||
    constructorName === "CSSScopeRule" ||
    constructorName === "CSSStartingStyleRule"
  ) {
    return "unknown";
  }

  return typeof conditionText === "string" ? "unknown" : "active";
}

function isScopeRule(rule: CSSRule) {
  return rule.constructor?.name === "CSSScopeRule";
}

function scopeContext(
  rule: CSSRule,
  styleScopeRoot: Document | Element | ShadowRoot | null
): ScopeContext {
  const scope = rule as CSSRule & {
    end?: string | null;
    start?: string | null;
  };
  return {
    end: typeof scope.end === "string" ? scope.end : null,
    // Imported stylesheets have no ownerNode. Keep the originating sheet's
    // owner scope root throughout the import graph.
    implicitRoot: styleScopeRoot,
    start: typeof scope.start === "string" ? scope.start : null,
  };
}

function implicitScopeRoot(sheet: CSSStyleSheet, treeRoot: Document | ShadowRoot) {
  const ownerParent = sheet.ownerNode?.parentNode;
  if (ownerParent instanceof Element || ownerParent instanceof ShadowRoot) {
    return ownerParent;
  }

  if (treeRoot.adoptedStyleSheets.includes(sheet)) {
    return treeRoot;
  }

  return null;
}

function isStyleRule(rule: CSSRule): rule is CSSStyleRule {
  const candidate = rule as Partial<CSSStyleRule>;
  return typeof candidate.selectorText === "string" && candidate.style !== undefined;
}

function isNestedDeclarationsRule(
  rule: CSSRule
): rule is CSSRule & { style: CSSStyleDeclaration } {
  return (
    rule.constructor?.name === "CSSNestedDeclarations" &&
    (rule as CSSRule & { style?: CSSStyleDeclaration }).style !== undefined
  );
}

function matchRuleSelector(
  element: Element,
  selector: string,
  context: RuleContext
): "matches" | "does-not-match" | "unknown" {
  if (context.scopes.length > 0) {
    return matchScopedRuleSelector(element, selector, context.scopes);
  }

  try {
    return element.matches(selector) ? "matches" : "does-not-match";
  } catch {
    return context.activity === "unknown" ? "unknown" : "does-not-match";
  }
}

function matchScopedRuleSelector(
  element: Element,
  selector: string,
  scopes: readonly ScopeContext[]
): "matches" | "does-not-match" | "unknown" {
  const treeRoot = element.getRootNode();
  if (!(treeRoot instanceof Document || treeRoot instanceof ShadowRoot)) {
    return "unknown";
  }

  let containingScopes: Array<Document | Element | ShadowRoot> = [treeRoot];
  let hasUnknownPath = false;
  for (const scope of scopes) {
    const nextScopes = new Set<Document | Element | ShadowRoot>();

    for (const containingScope of containingScopes) {
      const possibleRoots = scope.start
        ? scopedQuery(containingScope, scope.start)
        : scope.implicitRoot
          ? new Set([scope.implicitRoot])
          : new Set<Document | Element | ShadowRoot>();

      if (!possibleRoots) {
        hasUnknownPath = true;
        continue;
      }

      if (
        scope.start &&
        containingScope instanceof ShadowRoot &&
        rootContainsElement(containingScope, element)
      ) {
        // Chromium does not bind `:scope` to ShadowRoot for selector queries.
        // Keep an unmatched root-relative start as a possible path.
        hasUnknownPath = true;
      }

      // ParentNode queries exclude their root. A nested scope start may
      // explicitly anchor the containing scope; preserve that path as unknown
      // rather than parsing selector-list branches ourselves.
      if (
        scope.start &&
        containingScope instanceof Element &&
        rootContainsElement(containingScope, element)
      ) {
        try {
          if (containingScope.matches(scope.start)) hasUnknownPath = true;
        } catch {
          hasUnknownPath = true;
        }
      }

      for (const scopeRoot of possibleRoots) {
        if (
          !rootContainsRoot(containingScope, scopeRoot) ||
          !rootContainsElement(scopeRoot, element)
        ) {
          continue;
        }

        if (scope.end) {
          const possibleLimits = scopedQuery(scopeRoot, scope.end);
          if (!possibleLimits) {
            hasUnknownPath = true;
            continue;
          }
          if (
            Array.from(possibleLimits).some((limit) =>
              rootContainsElement(limit, element)
            )
          ) {
            continue;
          }
        }

        nextScopes.add(scopeRoot);
      }
    }

    if (nextScopes.size === 0) {
      return hasUnknownPath ? "unknown" : "does-not-match";
    }
    containingScopes = Array.from(nextScopes);
  }

  for (const containingScope of containingScopes) {
    const matches = scopedQuery(containingScope, selector);
    if (!matches) {
      hasUnknownPath = true;
      continue;
    }
    if (matches.has(element)) return "matches";

    // ParentNode query APIs intentionally exclude their Element root. Native
    // matches() can still prove whether a selector anchors that root without
    // parsing selector syntax ourselves.
    if (containingScope === element && containingScope instanceof Element) {
      try {
        if (containingScope.matches(selector)) return "matches";
      } catch {
        hasUnknownPath = true;
      }
      continue;
    }

    // Chromium cannot bind :scope/:host to a ShadowRoot in selector queries.
    if (containingScope instanceof ShadowRoot) {
      hasUnknownPath = true;
    }
  }

  return hasUnknownPath ? "unknown" : "does-not-match";
}

function scopedQuery(root: Document | Element | ShadowRoot, selector: string) {
  try {
    return new Set<Element>(root.querySelectorAll(selector));
  } catch {
    return undefined;
  }
}

function rootContainsElement(root: Document | Element | ShadowRoot, element: Element) {
  return root === element || root.contains(element);
}

function rootContainsRoot(
  containingRoot: Document | Element | ShadowRoot,
  candidateRoot: Document | Element | ShadowRoot
) {
  return (
    containingRoot === candidateRoot ||
    (candidateRoot instanceof Element && containingRoot.contains(candidateRoot))
  );
}

function expressionMatchesComputedValue({
  computed,
  computedStyle,
  expression,
  property,
  probe,
  sourceProperty,
}: {
  computed: string;
  computedStyle: CSSStyleDeclaration;
  expression: string;
  property: InspectedLayoutProperty;
  probe: HTMLElement | null;
  sourceProperty: string;
}) {
  if (
    !probe ||
    expressionDependsOnLayoutContext(expression, computedStyle) ||
    splitTopLevelWhitespace(expression).length > 1
  ) {
    return undefined;
  }

  for (const variable of extractVariables(expression)) {
    probe.style.setProperty(variable, computedStyle.getPropertyValue(variable));
  }
  applyProbeContext(probe, computedStyle);
  probe.style.removeProperty(sourceProperty);
  probe.style.setProperty(sourceProperty, expression);
  const resolved = getComputedStyle(probe).getPropertyValue(property);
  probe.style.removeProperty(sourceProperty);
  return samePixelValue(resolved, computed);
}

function declarationExpressionIsSafelyValid(
  candidate: DeclarationCandidate,
  computedStyle: CSSStyleDeclaration
) {
  const resolved = resolveSimpleDeclarationExpression(
    candidate.expression,
    computedStyle
  );
  if (!resolved) return false;

  if (typeof CSS !== "undefined" && typeof CSS.supports === "function") {
    return CSS.supports(candidate.sourceProperty, resolved);
  }

  const style = document.createElement("div").style;
  style.setProperty(candidate.sourceProperty, resolved);
  return style.getPropertyValue(candidate.sourceProperty) !== "";
}

function resolveSimpleDeclarationExpression(
  expression: string,
  computedStyle: CSSStyleDeclaration
) {
  let resolved = expression;
  for (const variable of extractVariables(expression)) {
    const value = computedStyle.getPropertyValue(variable).trim();
    if (!value || /var\s*\(/i.test(value)) return undefined;
    const escapedVariable = variable.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    resolved = resolved.replace(
      new RegExp(`var\\(\\s*${escapedVariable}\\s*\\)`, "gi"),
      value
    );
  }
  return /var\s*\(/i.test(resolved) ? undefined : resolved;
}

function applyProbeContext(probe: HTMLElement, computedStyle: CSSStyleDeclaration) {
  probe.style.borderTopStyle = computedStyle.borderTopStyle;
  probe.style.borderRightStyle = computedStyle.borderRightStyle;
  probe.style.borderBottomStyle = computedStyle.borderBottomStyle;
  probe.style.borderLeftStyle = computedStyle.borderLeftStyle;
  probe.style.boxSizing = computedStyle.boxSizing;
  probe.style.direction = computedStyle.direction;
  probe.style.fontSize = computedStyle.fontSize;
  probe.style.lineHeight = computedStyle.lineHeight;
  probe.style.writingMode = computedStyle.writingMode;
}

function expressionDependsOnLayoutContext(
  expression: string,
  computedStyle: CSSStyleDeclaration,
  visitedVariables = new Set<string>()
): boolean {
  if (
    expression.includes("%") ||
    /(^|[^\w-])(auto|min-content|max-content|fit-content|stretch|contain|content|available|inherit|initial|unset|revert|revert-layer)(?![\w-])/i.test(
      expression
    ) ||
    /(?:^|[^\w-])-?(?:\d*\.?\d+)(?:cqw|cqh|cqi|cqb|cqmin|cqmax|lh|rlh)(?![\w-])/i.test(
      expression
    )
  ) {
    return true;
  }

  for (const variable of extractVariables(expression)) {
    if (visitedVariables.has(variable)) return true;
    const variableValue = computedStyle.getPropertyValue(variable).trim();
    if (!variableValue) return true;

    const nextVisited = new Set(visitedVariables);
    nextVisited.add(variable);
    if (expressionDependsOnLayoutContext(variableValue, computedStyle, nextVisited)) {
      return true;
    }
  }

  return false;
}

function createExpressionProbe(computedStyle: CSSStyleDeclaration) {
  if (!document.documentElement) return null;

  const probe = document.createElement("div");
  probe.dataset.commaLayoutInspectorUi = "true";
  Object.assign(probe.style, {
    contain: "strict",
    fontSize: computedStyle.fontSize,
    height: "0",
    left: "-10000px",
    pointerEvents: "none",
    position: "fixed",
    top: "-10000px",
    visibility: "hidden",
  });
  document.documentElement.append(probe);
  return probe;
}

function extractVariables(expression: string) {
  return Array.from(expression.matchAll(variablePattern), (match) => match[1]).filter(
    (name): name is string => name !== undefined
  );
}

function uniqueDeclarationExpressions(expressions: readonly DeclarationExpression[]) {
  const seen = new Set<string>();
  return expressions.filter(({ expression, sourceProperty }) => {
    const key = `${sourceProperty}\u0000${expression}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function uniqueDeclarationBlockExpressions(
  expressions: readonly DeclarationExpression[]
) {
  const seen = new Set<string>();
  return expressions.filter(({ expression }) => {
    // CSSOM may expose the same authored shorthand through both the shorthand
    // and its expanded longhand (and physical/logical aliases). Treat an
    // identical expression from this declaration block as one candidate, keeping
    // the first, most property-specific source used by expressionsForProperty.
    if (seen.has(expression)) return false;
    seen.add(expression);
    return true;
  });
}

function singleCandidate(candidates: readonly DeclarationCandidate[]) {
  return candidates.length === 1 ? candidates[0] : undefined;
}

function inferToken(
  property: InspectedLayoutProperty,
  computed: string,
  computedStyle: CSSStyleDeclaration
) {
  const value = pixelValue(computed);
  if (value === undefined) return undefined;

  const matches = customPropertyNames(computedStyle).filter((variable) => {
    if (!isVariableRelevantToProperty(variable, property)) return false;
    return samePixelValue(computedStyle.getPropertyValue(variable), computed);
  });

  return matches.length === 1 ? matches[0] : undefined;
}

function customPropertyNames(computedStyle: CSSStyleDeclaration) {
  return Array.from(computedStyle).filter((property) => property.startsWith("--"));
}

export function isVariableRelevantToProperty(
  variable: string,
  property: InspectedLayoutProperty
) {
  const name = variable.toLowerCase();
  if (property.startsWith("border-")) {
    return (
      name.includes("border-width") ||
      name.includes("stroke-width") ||
      name.includes("line-width")
    );
  }
  if (property === "width" || property === "height") {
    return /(space|spacing|size|width|height|container)/.test(name);
  }
  return /(space|spacing|gap|gutter)/.test(name);
}

function samePixelValue(left: string, right: string) {
  const leftValue = pixelValue(left);
  const rightValue = pixelValue(right);
  return (
    leftValue !== undefined &&
    rightValue !== undefined &&
    Math.abs(leftValue - rightValue) <= pixelTolerance
  );
}

function pixelValue(value: string) {
  const match = /^(-?\d*\.?\d+)px$/.exec(value.trim());
  if (!match?.[1]) return undefined;
  const parsed = Number.parseFloat(match[1]);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function physicalSide(property: InspectedLayoutProperty) {
  if (property.includes("-top")) return 0;
  if (property.includes("-right")) return 1;
  if (property.includes("-bottom")) return 2;
  if (property.includes("-left")) return 3;
  return undefined;
}

function sideName(side: number) {
  return ["top", "right", "bottom", "left"][side] ?? "top";
}

function isHorizontalWritingMode(computedStyle: CSSStyleDeclaration) {
  return !computedStyle.writingMode || computedStyle.writingMode === "horizontal-tb";
}
