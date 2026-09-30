import "@comma/ui/styles.css";
import "./styles.css";

import { LayoutInspector } from "@comma/layout-inspector";
import { Button, Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui";
import { resolveAuthoredLayoutValues } from "../../../../../packages/layout-inspector/src/authored-values";
import { StrictMode, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

declare global {
  interface Window {
    resolveShadowWidth?: (targetId: string) => {
      computed: string;
      confidence: string;
      variables: string[];
    };
    setFixtureHostPadding?: (value: number) => void;
  }
}

const disabledFixtureSheet = (
  document.getElementById("fixture-disabled-sheet") as HTMLStyleElement | null
)?.sheet;
if (disabledFixtureSheet) disabledFixtureSheet.disabled = true;

function ShadowScopeFixture() {
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const shadowRoot = host.shadowRoot ?? host.attachShadow({ mode: "open" });
    if (shadowRoot.childNodes.length === 0) {
      shadowRoot.innerHTML = `
        <link rel="stylesheet" href="/shadow-imported.css" />
        <style>
          .fixture-shadow-scope-target,
          .fixture-shadow-nested-scope-target,
          .fixture-shadow-host-nesting-target,
          .fixture-shadow-link-target {
            --fixture-shadow-scope-loser: 100px;
            display: block;
            min-height: 40px;
            width: var(--fixture-shadow-scope-loser);
          }

          @scope {
            :scope > #fixture-shadow-scope-target {
              width: 100px;
            }

            @scope (:scope > .fixture-shadow-inner) {
              #fixture-shadow-nested-scope-target {
                width: 100px;
              }
            }
          }

          :host {
            #fixture-shadow-host-nesting-target {
              width: 100px;
            }
          }
        </style>
        <div
          class="fixture-shadow-scope-target"
          data-testid="shadow-scope-target"
          id="fixture-shadow-scope-target"
        >
          Shadow scope target
        </div>
        <div class="fixture-shadow-inner">
          <div
            class="fixture-shadow-nested-scope-target"
            data-testid="shadow-nested-scope-target"
            id="fixture-shadow-nested-scope-target"
          >
            Nested shadow scope target
          </div>
        </div>
        <div
          class="fixture-shadow-link-target"
          data-testid="shadow-link-target"
          id="fixture-shadow-link-target"
        >
          Shadow linked stylesheet target
        </div>
        <div
          class="fixture-shadow-host-nesting-target"
          data-testid="shadow-host-nesting-target"
          id="fixture-shadow-host-nesting-target"
        >
          Shadow host nesting target
        </div>
      `;
    }

    window.resolveShadowWidth = (targetId) => {
      const target = shadowRoot.getElementById(targetId);
      if (!target) throw new Error(`Shadow target ${targetId} was unavailable.`);
      const width = resolveAuthoredLayoutValues(target).width;
      return {
        computed: width.computed,
        confidence: width.confidence,
        variables: width.variables,
      };
    };

    return () => {
      delete window.resolveShadowWidth;
    };
  }, []);

  return <div ref={hostRef} />;
}

function CrossTreeProvenanceFixture() {
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const outerRoot = host.shadowRoot ?? host.attachShadow({ mode: "open" });
    outerRoot.innerHTML = `
      <style>
        .fixture-cross-tree-inner-host {
          --fixture-host-height-loser: 40px;
          --fixture-host-height-choice: 80px;

          display: block;
          width: 220px;
          height: var(--fixture-host-height-loser);
        }

        .fixture-slotted-provenance-target {
          --fixture-slotted-border-width-loser: 4px;
          --fixture-slotted-border-width-choice: 8px;

          display: block;
          width: 160px;
          min-height: 40px;
          border-top-color: #7455c8;
          border-top-style: solid;
          border-top-width: var(--fixture-slotted-border-width-loser);
        }
      </style>
      <div
        class="fixture-cross-tree-inner-host"
        data-testid="host-provenance-target"
        exportparts="fixture-provenance-target: fixture-exported-provenance-target"
        id="fixture-cross-tree-inner-host"
      >
        <div
          class="fixture-slotted-provenance-target"
          data-testid="slotted-provenance-target"
          id="fixture-slotted-provenance-target"
          slot="fixture-provenance-slot"
        >
          Slotted provenance target
        </div>
      </div>
    `;

    const innerHost = outerRoot.querySelector<HTMLElement>(
      ".fixture-cross-tree-inner-host"
    );
    if (!innerHost) throw new Error("Cross-tree fixture host was unavailable.");
    const innerRoot = innerHost.shadowRoot ?? innerHost.attachShadow({ mode: "open" });
    innerRoot.innerHTML = `
      <style>
        :host {
          height: 40px !important;
        }

        ::slotted(.fixture-slotted-provenance-target) {
          border-top-width: 4px !important;
        }

        .fixture-part-provenance-target {
          --fixture-part-spacing-loser: 24px;
          --fixture-part-spacing-choice: 40px;

          display: block;
          width: 160px;
          min-height: 40px;
          margin-top: var(--fixture-part-spacing-loser);
        }
      </style>
      <slot name="fixture-provenance-slot"></slot>
      <div
        class="fixture-part-provenance-target"
        data-testid="part-provenance-target"
        id="fixture-part-provenance-target"
        part="fixture-provenance-target"
      >
        Part provenance target
      </div>
    `;
  }, []);

  return (
    <div
      className="fixture-cross-tree-outer-host"
      data-testid="cross-tree-provenance-host"
      ref={hostRef}
    />
  );
}

function LayoutInspectorFixture() {
  const [activationCount, setActivationCount] = useState(0);
  const [hostPadding, setHostPadding] = useState(4);
  const openMenuForInspector = new URLSearchParams(window.location.search).has(
    "open-menu"
  );

  useEffect(() => {
    window.setFixtureHostPadding = setHostPadding;
    return () => {
      delete window.setFixtureHostPadding;
    };
  }, []);

  return (
    <main className="fixture-page">
      <MenuTrigger defaultOpen={openMenuForInspector}>
        <Button className="fixture-menu-trigger" data-testid="fixture-menu-trigger">
          Open menu
        </Button>
        <MenuPopover placement="top start">
          <Menu aria-label="Fixture menu">
            <MenuItem id="settings">
              <span className="fixture-menu-settings-label">Settings</span>
            </MenuItem>
            <MenuItem id="sign-out" tone="destructive">
              Sign out
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      <button
        className="fixture-card"
        data-testid="layout-target"
        onClick={() => setActivationCount((count) => count + 1)}
        type="button"
      >
        <span className="fixture-cell fixture-cell--wide">Alpha</span>
        <span className="fixture-cell">Beta</span>
        <span className="fixture-cell">Gamma</span>
      </button>
      <p data-testid="activation-count">Activation count: {activationCount}</p>
      <button
        className="fixture-transition-target"
        data-testid="transition-target"
        type="button"
      >
        Transition target
      </button>
      <button
        className="fixture-host-style-target"
        data-testid="host-style-target"
        style={{ paddingTop: `${hostPadding}px` }}
        type="button"
      >
        Host style target
      </button>
      <button
        className="fixture-cascade-target"
        data-testid="cascade-target"
        type="button"
      >
        Cascade target
      </button>
      <button
        className="fixture-animation-cascade-target"
        data-testid="animation-cascade-target"
        id="fixture-animation-cascade-target"
        type="button"
      >
        Animated cascade target
      </button>
      <div className="fixture-cascade-same-parent">
        <button
          className="fixture-cascade-same-target"
          data-testid="cascade-same-target"
          id="fixture-cascade-same-target"
          type="button"
        >
          Same-value cascade target
        </button>
      </div>
      <div
        className="fixture-gap-target fixture-gap-target--percent"
        data-testid="percent-gap-target"
      >
        <span>Percent A</span>
        <span>Percent B</span>
      </div>
      <div
        className="fixture-gap-target fixture-gap-target--calc"
        data-testid="calc-gap-target"
      >
        <span>Calc A</span>
        <span>Calc B</span>
      </div>
      <div
        className="fixture-auto-flex-gap-target fixture-auto-flex-gap-target--percent"
        data-testid="auto-flex-percent-gap-target"
      >
        <span>Auto percent A</span>
        <span>Auto percent B</span>
      </div>
      <div
        className="fixture-auto-flex-gap-target fixture-auto-flex-gap-target--calc"
        data-testid="auto-flex-calc-gap-target"
      >
        <span>Auto calc A</span>
        <span>Auto calc B</span>
      </div>
      <div className="fixture-width-auto-parent">
        <div
          className="fixture-width-auto-target"
          data-testid="width-auto-target"
          id="fixture-width-auto-target"
        >
          Width auto target
        </div>
      </div>
      <div
        className="fixture-import-target"
        data-testid="import-target"
        id="fixture-import-target"
      >
        Imported winner target
      </div>
      <div className="fixture-inherit-parent">
        <div
          className="fixture-inherit-target"
          data-testid="inherit-target"
          id="fixture-inherit-target"
        >
          Inherited conditional winner target
        </div>
      </div>
      <div
        className="fixture-border-source-target"
        data-testid="border-keyword-target"
        id="fixture-border-keyword-target"
      >
        Border keyword target
      </div>
      <div
        className="fixture-border-source-target"
        data-testid="border-shorthand-target"
        id="fixture-border-shorthand-target"
      >
        Border shorthand target
      </div>
      <div
        className="fixture-inactive-sheet-target"
        data-testid="inactive-media-sheet-target"
        id="fixture-inactive-media-target"
      >
        Inactive media sheet target
      </div>
      <div
        className="fixture-inactive-sheet-target"
        data-testid="disabled-sheet-target"
        id="fixture-disabled-sheet-target"
      >
        Disabled sheet target
      </div>
      <div
        className="fixture-declaration-identity-target"
        data-testid="declaration-identity-target"
      >
        Declaration identity target
      </div>
      <div
        className="fixture-unrelated-nesting-target"
        data-testid="unrelated-subtree-nesting-target"
        id="fixture-unrelated-subtree-nesting-target"
      >
        Unrelated-subtree nesting target
      </div>
      <div
        className="fixture-absent-trigger-nesting-target"
        data-testid="absent-trigger-nesting-target"
        id="fixture-absent-trigger-nesting-target"
      >
        Absent-trigger nesting target
      </div>
      <div className="fixture-container-query-parent">
        <div
          className="fixture-context-cascade-target fixture-container-query-target"
          data-testid="container-query-target"
          id="fixture-container-query-target"
        >
          Container query target
        </div>
        <div
          className="fixture-context-cascade-target fixture-nested-container-target"
          data-testid="nested-container-target"
          id="fixture-nested-container-target"
        >
          Nested container declarations target
        </div>
        <div
          className="fixture-context-cascade-target fixture-font-context-target"
          data-testid="font-context-target"
          id="fixture-font-context-target"
        >
          Font-context conditional winner target
        </div>
        <div className="fixture-nested-sibling-trigger" />
        <div
          className="fixture-context-cascade-target fixture-nested-sibling-target"
          data-testid="nested-sibling-target"
          id="fixture-nested-sibling-target"
        >
          Nested sibling rule target
        </div>
      </div>
      <div className="fixture-scope-root">
        <div
          className="fixture-context-cascade-target fixture-scope-target"
          data-testid="scope-target"
          id="fixture-scope-target"
        >
          Scope target
        </div>
        <div
          className="fixture-context-cascade-target fixture-scope-nesting-target"
          data-testid="scope-nesting-target"
          id="fixture-scope-nesting-target"
        >
          Nested selector scope target
        </div>
        <div className="fixture-nested-scope-parent">
          <div
            className="fixture-context-cascade-target fixture-nested-scope-target"
            data-testid="nested-scope-target"
            id="fixture-nested-scope-target"
          >
            Nested scope rule target
          </div>
        </div>
      </div>
      <div className="fixture-overlap-scope-root">
        <div className="fixture-overlap-scope-root">
          <div className="fixture-overlap-scope-limit">
            <div
              className="fixture-context-cascade-target fixture-overlap-scope-target"
              data-testid="overlap-scope-target"
              id="fixture-overlap-scope-target"
            >
              Overlapping scope target
            </div>
          </div>
        </div>
      </div>
      <ShadowScopeFixture />
      <CrossTreeProvenanceFixture />
      <div
        className="fixture-margin-flex-gap-target fixture-margin-flex-gap-target--percent"
        data-testid="margin-flex-percent-gap-target"
      >
        <span>Margin percent A</span>
        <span>Margin percent B</span>
      </div>
      <div
        className="fixture-margin-flex-gap-target fixture-margin-flex-gap-target--calc"
        data-testid="margin-flex-calc-gap-target"
      >
        <span>Margin calc A</span>
        <span>Margin calc B</span>
      </div>
      <div
        className="fixture-distributed-flex-gap-target"
        data-testid="distributed-flex-gap-target"
      >
        <span>Distributed A</span>
        <span>Distributed B</span>
      </div>
      <div
        className="fixture-display-contents-target"
        data-testid="display-contents-target"
      >
        <span>Contents A</span>
        <div className="fixture-display-contents-wrapper">
          <span>Contents B</span>
        </div>
      </div>
      <div
        className="fixture-anonymous-text-flex-target"
        data-testid="anonymous-text-flex-target"
      >
        {"\u00a0"}
        <span>Element item</span>
      </div>
      <div
        className="fixture-collapsed-grid-target"
        data-testid="collapsed-grid-target"
      >
        <span>Grid A</span>
        <span>Grid B</span>
      </div>
      <div className="fixture-transform-ancestor">
        <button
          className="fixture-transform-target"
          data-testid="transform-target"
          type="button"
        >
          Transformed target
        </button>
      </div>
      <div className="fixture-individual-scale-ancestor">
        <button
          className="fixture-individual-transform-target"
          data-testid="individual-scale-target"
          type="button"
        >
          Individual scale target
        </button>
      </div>
      <div className="fixture-individual-rotate-ancestor">
        <button
          className="fixture-individual-transform-target"
          data-testid="individual-rotate-target"
          type="button"
        >
          Individual rotate target
        </button>
      </div>
      <div className="fixture-individual-identity-ancestor">
        <button
          className="fixture-individual-transform-target"
          data-testid="individual-identity-target"
          type="button"
        >
          Individual identity target
        </button>
      </div>
      <div className="fixture-perspective-ancestor">
        <button
          className="fixture-individual-transform-target"
          data-testid="perspective-target"
          type="button"
        >
          Perspective target
        </button>
      </div>
      <button
        className="fixture-collision-target"
        data-testid="collision-target"
        type="button"
      >
        <span>One</span>
        <span>Two</span>
      </button>
      <div className="fixture-inspector-stacking-context">
        <LayoutInspector defaultActive />
      </div>
    </main>
  );
}

const root = document.getElementById("root");
if (!root) throw new Error("Layout Inspector fixture root was not found.");

createRoot(root).render(
  <StrictMode>
    <LayoutInspectorFixture />
  </StrictMode>
);
