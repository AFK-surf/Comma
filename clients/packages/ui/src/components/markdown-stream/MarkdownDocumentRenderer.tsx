import NodeRenderer, {
  getCustomNodeComponents,
  removeCustomComponents,
  renderNode,
  setCustomComponents,
  type CustomComponentMap,
  type NodeComponentProps,
  type NodeRendererProps,
  type RenderContext,
} from "markstream-react";
import {
  createContext,
  useContext,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { BaseNode, ParsedNode } from "stream-markdown-parser";
import {
  markdownPresentationSlots,
  type MarkdownBlockPresentation,
  type MarkdownPresentationSlot,
} from "./blockPresentation";

type PresentationProps = Omit<
  NodeRendererProps,
  "content" | "nodes" | "customMarkdownIt" | "parseOptions"
>;

export interface MarkdownDocumentRendererProps extends PresentationProps {
  nodes: readonly BaseNode[];
  customComponents?: CustomComponentMap;
  /** Content previously scheduled each root independently; nodes scheduled one tree. */
  sourceMode?: "content" | "nodes";
  /** First root that is still receiving visible text. Earlier roots stay settled. */
  liveRootStart?: number;
  /** Comma's presentation contexts wrap each root without owning its React identity. */
  wrapRoot?: (element: ReactNode, index: number) => ReactNode;
  /** Group prose roots and isolate rich blocks without splitting the document. */
  blockPresentation?: MarkdownBlockPresentation;
}

/**
 * One owner for the current parsed tree and its presentation lifetime. The public
 * renderNode dispatcher recursively receives fresh AST nodes; NodeRenderer's
 * raw-text cache is deliberately not another owner of the document.
 */
export function MarkdownDocumentRenderer({
  nodes,
  customComponents,
  sourceMode = "nodes",
  liveRootStart = 0,
  wrapRoot,
  blockPresentation = "document",
  ...props
}: MarkdownDocumentRendererProps) {
  const generatedId = useId();
  const documentKey = `${props.customId ?? generatedId}:${props.indexKey ?? "document"}`;
  const documentState = useRef({ key: documentKey, text: new Map<string, string>() });
  if (documentState.current.key !== documentKey) {
    documentState.current = { key: documentKey, text: new Map<string, string>() };
  }
  const textStreamState = documentState.current.text;
  const versionRef = useRef({ nodes, version: 0 });
  if (versionRef.current.nodes !== nodes) {
    versionRef.current = { nodes, version: versionRef.current.version + 1 };
  }
  const context = useMemo<RenderContext>(
    () => ({
      ...(props.customId === undefined ? {} : { customId: props.customId }),
      indexKey: documentKey,
      ...(props.isDark === undefined ? {} : { isDark: props.isDark }),
      typewriter: false,
      fade: props.fade ?? false,
      textStreamState,
      ...(props.customHtmlTags === undefined
        ? {}
        : { customHtmlTags: props.customHtmlTags }),
      htmlPolicy: props.htmlPolicy ?? "escape",
      ...(props.showTooltips === undefined ? {} : { showTooltips: props.showTooltips }),
      ...(props.renderCodeBlocksAsPre === undefined
        ? {}
        : { renderCodeBlocksAsPre: props.renderCodeBlocksAsPre }),
      codeBlockStream: props.codeBlockStream ?? true,
      codeBlockProps: {
        ...(props.showTooltips === undefined
          ? {}
          : { showTooltips: props.showTooltips }),
        ...props.codeBlockProps,
      },
      ...(props.mermaidProps === undefined ? {} : { mermaidProps: props.mermaidProps }),
      ...(props.d2Props === undefined ? {} : { d2Props: props.d2Props }),
      ...(props.infographicProps === undefined
        ? {}
        : { infographicProps: props.infographicProps }),
      codeBlockThemes: {
        ...(props.themes === undefined ? {} : { themes: props.themes }),
        ...(props.codeBlockDarkTheme === undefined
          ? {}
          : { darkTheme: props.codeBlockDarkTheme }),
        ...(props.codeBlockLightTheme === undefined
          ? {}
          : { lightTheme: props.codeBlockLightTheme }),
        ...(props.langs === undefined ? {} : { langs: props.langs }),
        ...(props.codeBlockMonacoOptions === undefined
          ? {}
          : { monacoOptions: props.codeBlockMonacoOptions }),
        ...(props.codeBlockMinWidth === undefined
          ? {}
          : { minWidth: props.codeBlockMinWidth }),
        ...(props.codeBlockMaxWidth === undefined
          ? {}
          : { maxWidth: props.codeBlockMaxWidth }),
      },
      events: {
        ...(props.onCopy === undefined ? {} : { onCopy: props.onCopy }),
        ...(props.onHandleArtifactClick === undefined
          ? {}
          : { onHandleArtifactClick: props.onHandleArtifactClick }),
      },
    }),
    [
      documentKey,
      props.codeBlockDarkTheme,
      props.codeBlockLightTheme,
      props.codeBlockMaxWidth,
      props.codeBlockMinWidth,
      props.codeBlockMonacoOptions,
      props.codeBlockProps,
      props.codeBlockStream,
      props.customHtmlTags,
      props.customId,
      props.d2Props,
      props.fade,
      props.htmlPolicy,
      props.infographicProps,
      props.isDark,
      props.langs,
      props.mermaidProps,
      props.onCopy,
      props.onHandleArtifactClick,
      props.renderCodeBlocksAsPre,
      props.showTooltips,
      props.themes,
      textStreamState,
    ]
  );
  const liveContext = useMemo<RenderContext>(
    () => ({ ...context, typewriter: Boolean(props.typewriter && !props.final) }),
    [context, props.final, props.typewriter]
  );
  // The map and context identity are stable while text changes. Custom text nodes
  // can inspect the current version without rerendering every settled root.
  context.streamRenderVersion = versionRef.current.version;
  liveContext.streamRenderVersion = versionRef.current.version;

  const resolveContexts = useMemo(() => {
    let cached:
      | {
          hostComponents: RenderContext["customComponents"];
          settled: RenderContext;
          live: RenderContext;
        }
      | undefined;
    return (hostContext: RenderContext | undefined) => {
      // NodeRenderer owns the public registry subscription. Its updated context
      // invalidates this document's mapping without another subscription or a
      // registry write during render. Keep local overrides ahead of that scope.
      if (!cached || cached.hostComponents !== hostContext?.customComponents) {
        const components = {
          ...getCustomNodeComponents(context.customId),
          ...customComponents,
        };
        cached = {
          hostComponents: hostContext?.customComponents,
          settled: { ...context, customComponents: components },
          live: { ...liveContext, customComponents: components },
        };
      }
      cached.settled.streamRenderVersion = versionRef.current.version;
      cached.live.streamRenderVersion = versionRef.current.version;
      return cached;
    };
  }, [context, liveContext, customComponents]);

  const slots = useMemo(
    () => markdownPresentationSlots(nodes, blockPresentation),
    [nodes, blockPresentation]
  );
  const snapshot = useMemo(
    () => ({
      nodes,
      slots,
      documentKey,
      resolveContexts,
      liveRootStart,
      wrapRoot,
      showCursor: Boolean(props.typewriter && !props.final),
    }),
    [
      nodes,
      slots,
      documentKey,
      resolveContexts,
      liveRootStart,
      wrapRoot,
      props.typewriter,
      props.final,
    ]
  );
  const scheduledNodes = useMemo(
    () =>
      slots.map((slot, slotIndex) => {
        const node = nodes[slot.rootIndices[0]!]!;
        return slot.kind
          ? {
              type: "comma_document_bubble",
              raw: node.raw,
              commaDocumentSlotIndex: slotIndex,
            }
          : { ...node, commaDocumentSlotIndex: slotIndex };
      }),
    [nodes, slots]
  );
  const hostScope = `comma-document-layout-${generatedId}`;
  const componentNames = [
    ...new Set([
      ...nodes.map((node) => node.type),
      // Code dispatch tries the fence language before code_block. Reserve each
      // current root's first lookup key so a later global language registration
      // also reaches DocumentSlot and its original document scope.
      ...nodes.flatMap((node) => {
        if (node.type !== "code_block") return [];
        const language = String(
          (node as ParsedNode & { language?: string }).language ?? ""
        )
          .trim()
          .split(/\s+/)[0]!
          .split(":")[0]!
          .toLowerCase();
        return language ? [language] : [];
      }),
      "code_block",
      "mermaid",
      "d2",
      "infographic",
      "comma_document_bubble",
    ]),
  ]
    .toSorted()
    .join("\0");
  const hostComponents = useMemo<CustomComponentMap>(
    () =>
      Object.fromEntries(
        componentNames.split("\0").map((name) => [name, DocumentSlot])
      ),
    [componentNames]
  );
  const [registered, setRegistered] = useState(false);
  useLayoutEffect(() => {
    setCustomComponents(hostScope, hostComponents);
    setRegistered(true);
  }, [hostScope, hostComponents]);
  useLayoutEffect(() => () => removeCustomComponents(hostScope), [hostScope]);

  return (
    <DocumentSnapshotContext.Provider value={snapshot}>
      {registered ? (
        <NodeRenderer
          key={documentKey}
          {...props}
          {...contentSchedulingProps(sourceMode, scheduledNodes.length, props)}
          customId={hostScope}
          indexKey={documentKey}
          nodes={scheduledNodes}
          typewriter={false}
          fade={false}
          smoothStreaming={false}
        />
      ) : null}
    </DocumentSnapshotContext.Provider>
  );
}

interface DocumentSnapshot {
  nodes: readonly BaseNode[];
  slots: readonly MarkdownPresentationSlot[];
  documentKey: string;
  resolveContexts: (hostContext: RenderContext | undefined) => {
    settled: RenderContext;
    live: RenderContext;
  };
  liveRootStart: number;
  showCursor: boolean;
  wrapRoot: MarkdownDocumentRendererProps["wrapRoot"];
}

const DocumentSnapshotContext = createContext<DocumentSnapshot | null>(null);

type ScheduledNode = BaseNode & { commaDocumentSlotIndex: number };

function DocumentSlot({ node: scheduled, ctx }: NodeComponentProps<ScheduledNode>) {
  const snapshot = useContext(DocumentSnapshotContext)!;
  const slot = snapshot.slots[scheduled.commaDocumentSlotIndex];
  if (!slot) return null;
  const contexts = snapshot.resolveContexts(ctx);
  if (slot.kind && slot.kind !== "comma-inline") {
    return (
      <div className="markdown-stream-bubble" data-kind={slot.kind}>
        {slot.rootIndices.map((index) => (
          <div
            className="markdown-stream-bubble-block"
            data-node-type={snapshot.nodes[index]!.type}
            key={`${snapshot.documentKey}-${index}`}
          >
            {renderDocumentRoot(snapshot, contexts, index)}
          </div>
        ))}
      </div>
    );
  }
  return renderDocumentRoot(snapshot, contexts, slot.rootIndices[0]!);
}

function renderDocumentRoot(
  snapshot: DocumentSnapshot,
  contexts: ReturnType<DocumentSnapshot["resolveContexts"]>,
  index: number
) {
  const node = snapshot.nodes[index]!;
  const rendered = renderNode(
    node as ParsedNode,
    `${snapshot.documentKey}-${index}`,
    index >= snapshot.liveRootStart ? contexts.live : contexts.settled
  );
  return (
    <>
      {snapshot.wrapRoot ? snapshot.wrapRoot(rendered, index) : rendered}
      {snapshot.showCursor &&
      index === snapshot.nodes.length - 1 &&
      index >= snapshot.liveRootStart ? (
        <LiveCursor />
      ) : null}
    </>
  );
}

function LiveCursor() {
  const cursorRef = useRef<HTMLSpanElement>(null);
  // Only the last live slot is inspected. The upstream layout owner handles
  // viewport measurements and batching; this adds no independent observer/timer.
  useLayoutEffect(() => {
    const cursor = cursorRef.current;
    const root = cursor?.closest<HTMLElement>(".node-content");
    const container = cursor?.closest<HTMLElement>(".markdown-renderer");
    if (!cursor || !root || !container) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (
          !node.textContent?.trim() ||
          !parent ||
          parent.closest(
            "pre, code, figure, table, svg, .katex, .math-block, .math-inline, script, style, [aria-hidden='true']"
          )
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    let lastText: Node | null = null;
    let next: Node | null;
    while ((next = walker.nextNode())) lastText = next;
    if (!lastText?.textContent) {
      cursor.style.visibility = "hidden";
      return;
    }
    const range = document.createRange();
    const end = lastText.textContent.trimEnd().length;
    range.setStart(lastText, Math.max(0, end - 1));
    range.setEnd(lastText, end);
    const rects = range.getClientRects?.();
    const rect = rects?.[rects.length - 1];
    if (!rect) {
      cursor.style.visibility = "hidden";
      return;
    }
    const origin = container.getBoundingClientRect();
    cursor.style.visibility = "visible";
    cursor.style.transform = `translate(${rect.right - origin.left}px, ${rect.top - origin.top}px)`;
    cursor.style.height = `${rect.height}px`;
  });
  return <span aria-hidden="true" className="typewriter-cursor" ref={cursorRef} />;
}

function contentSchedulingProps(
  sourceMode: "content" | "nodes",
  count: number,
  props: PresentationProps
): Partial<NodeRendererProps> {
  if (sourceMode === "nodes") return {};
  const initial = Math.max(0, Math.trunc(props.initialRenderBatchSize ?? 40));
  const batch = props.batchRendering !== false && (props.renderBatchSize ?? 80) > 0;
  const windowSize = props.maxLiveNodes ?? 320;
  return {
    // Each old content host had one root, so every positive initial budget
    // displayed it immediately. A zero budget delayed all roots by one batch.
    batchRendering: batch && initial === 0,
    initialRenderBatchSize: initial === 0 ? 0 : Number.MAX_SAFE_INTEGER,
    // A stable whole-document budget matches parallel one-root batches without
    // resetting already-visible roots whenever the document gains a root.
    renderBatchSize: Number.MAX_SAFE_INTEGER,
    ...(windowSize > 0 ? { maxLiveNodes: Math.max(windowSize, count) } : {}),
  };
}
