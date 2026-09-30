import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  Catalog,
  Category,
  FrontmatterField,
  JobSnapshot,
  PromptDocument,
  PromptLine,
} from "../shared/schema";
import { DocumentSection } from "./components/DocumentSection";
import { JobPanel } from "./components/JobPanel";
import { PromptMap } from "./components/PromptMap";
import { AtlasApi } from "./lib/api";
import {
  buildPromptStages,
  promptCompositionLabel,
  promptStageAnchor,
  type PromptStage,
} from "./lib/catalog-order";
import {
  buildPendingChanges,
  documentTextStats,
  domId,
  duplicateGroups,
  effectiveLines,
  updateDraft,
  type DraftMap,
  type DuplicateOccurrence,
} from "./lib/editor";
import { clearStoredDrafts, loadDrafts, saveDrafts } from "./lib/storage";

const categoryLabels = {
  system: "System Prompts",
  tool: "Tools",
  skill: "Skills",
} as const;

const categoryOrder = ["system", "tool", "skill"] as const;

function stageDocumentId(
  stage: PromptStage,
  document: PromptDocument,
  canonicalStageByDocument: Map<string, string>,
): string {
  return canonicalStageByDocument.get(document.id) === stage.id
    ? document.id
    : `${stage.id}:${document.id}`;
}

function ErrorBanner({ message, onClose }: { message: string; onClose: () => void }) {
  return (
    <div className="error-banner" role="alert">
      <span>{message}</span>
      <button type="button" onClick={onClose} aria-label="关闭错误提示">
        关闭
      </button>
    </div>
  );
}

export default function App() {
  const [api, setApi] = useState<AtlasApi | null>(null);
  const [catalog, setCatalog] = useState<Catalog | null>(null);
  const [drafts, setDrafts] = useState<DraftMap>({});
  const [job, setJob] = useState<JobSnapshot | null>(null);
  const [duplicatesOnly, setDuplicatesOnly] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hydrated, setHydrated] = useState(false);
  const processedJob = useRef<string | null>(null);

  const loadCatalog = useCallback(async (client: AtlasApi) => {
    const next = await client.catalog();
    setCatalog(next);
    return next;
  }, []);

  useEffect(() => {
    let cancelled = false;
    void AtlasApi.connect()
      .then(async ({ api: client, currentJob }) => {
        if (cancelled) return;
        setApi(client);
        setJob(currentJob);
        const nextCatalog = await loadCatalog(client);
        if (cancelled) return;
        const stored = loadDrafts();
        if (stored) {
          const known = new Set(nextCatalog.documents.map((document) => document.id));
          setDrafts(
            Object.fromEntries(
              Object.entries(stored.drafts).filter(([documentId]) => known.has(documentId)),
            ),
          );
        }
        setHydrated(true);
      })
      .catch((reason: unknown) => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [loadCatalog]);

  useEffect(() => {
    if (hydrated && catalog) saveDrafts(catalog.catalogVersion, drafts);
  }, [catalog, drafts, hydrated]);

  useEffect(() => {
    if (!api || !job || (job.status !== "queued" && job.status !== "running")) return;
    const timer = window.setInterval(() => {
      void api
        .currentJob()
        .then((next) => setJob(next))
        .catch((reason: unknown) =>
          setError(reason instanceof Error ? reason.message : String(reason)),
        );
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [api, job]);

  useEffect(() => {
    if (!api || !job || job.status !== "succeeded" || processedJob.current === job.id) {
      return;
    }
    processedJob.current = job.id;
    if (job.kind === "apply") {
      setDrafts({});
      clearStoredDrafts();
    }
    void loadCatalog(api).catch((reason: unknown) =>
      setError(reason instanceof Error ? reason.message : String(reason)),
    );
  }, [api, job, loadCatalog]);

  const draftCount = Object.keys(drafts).length;
  const busy = job?.status === "queued" || job?.status === "running";
  const duplicatesByText = useMemo(
    () => (catalog ? duplicateGroups(catalog, {}) : new Map()),
    [catalog],
  );

  const promptStages = useMemo(() => {
    if (!catalog) return [];
    return buildPromptStages(catalog.documents);
  }, [catalog]);

  const canonicalStageByDocument = useMemo(() => {
    const canonical = new Map<string, string>();
    for (const stage of promptStages) {
      for (const document of stage.documents) {
        if (!canonical.has(document.id)) canonical.set(document.id, stage.id);
      }
    }
    return canonical;
  }, [promptStages]);

  const categoryDocuments = useMemo<Map<Category, PromptDocument[]>>(() => {
    if (!catalog) return new Map<Category, PromptDocument[]>();
    const seen = new Set<string>();
    const orderedDocuments = promptStages
      .flatMap((stage) => stage.documents)
      .filter((document) => {
        if (seen.has(document.id)) return false;
        seen.add(document.id);
        return true;
      });
    return new Map(
      categoryOrder.map((category) => [
        category,
        orderedDocuments.filter((document) => document.category === category),
      ]),
    );
  }, [catalog, promptStages]);

  const promptMapStages = useMemo(
    () =>
      promptStages.map((stage) => ({
        ...stage,
        lineCount: stage.documents.reduce(
          (sum, document) => sum + effectiveLines(document, drafts).length,
          0,
        ),
      })),
    [drafts, promptStages],
  );

  const totals = useMemo(() => {
    if (!catalog) return { documents: 0, lines: 0, characters: 0, words: 0, delta: 0 };
    let lines = 0;
    let characters = 0;
    let words = 0;
    let originalCharacters = 0;
    for (const document of catalog.documents) {
      const current = effectiveLines(document, drafts);
      const stats = documentTextStats(current);
      const original = documentTextStats(document.lines);
      lines += current.length;
      characters += stats.characters;
      words += stats.words;
      originalCharacters += original.characters;
    }
    return {
      documents: catalog.documents.length,
      lines,
      characters,
      words,
      delta: characters - originalCharacters,
    };
  }, [catalog, drafts]);

  const changeDocument = useCallback(
    (
      document: PromptDocument,
      lines: PromptLine[],
      frontmatter: FrontmatterField[],
    ) => {
      setDrafts((current) => updateDraft(current, document, lines, frontmatter));
    },
    [],
  );

  const jumpDuplicate = useCallback(
    (line: PromptLine, occurrences: DuplicateOccurrence[]) => {
      if (occurrences.length < 2) return;
      const currentIndex = occurrences.findIndex((item) => item.lineId === line.id);
      const next = occurrences[(currentIndex + 1 + occurrences.length) % occurrences.length]!;
      document
        .getElementById(domId("line", next.documentId, next.lineId))
        ?.scrollIntoView({ block: "center", behavior: "smooth" });
    },
    [],
  );

  const explainLine = useCallback(
    (documentId: string, lineId: string, context?: string) => {
      if (!api) return Promise.reject(new Error("尚未连接 Bun 后端"));
      return api.explain(documentId, lineId, context);
    },
    [api],
  );

  async function extract() {
    if (!api) return;
    if (draftCount > 0) {
      setError(`存在 ${draftCount} 份草稿；清空后才能全量提取。`);
      return;
    }
    try {
      setError(null);
      setJob(await api.extract());
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    }
  }

  async function saveAndApply() {
    if (!api || !catalog || draftCount === 0) return;
    try {
      setError(null);
      setJob(await api.apply(buildPendingChanges(catalog, drafts)));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    }
  }

  function clearDrafts() {
    setDrafts({});
    clearStoredDrafts();
  }

  if (!catalog) {
    return (
      <main className="loading-screen">
        <div className="loading-mark" aria-hidden="true" />
        <p>正在连接 Salix Prompt Atlas…</p>
        {error ? <ErrorBanner message={error} onClose={() => setError(null)} /> : null}
      </main>
    );
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand-block">
          <div className="brand-mark" aria-hidden="true">
            S
          </div>
          <div>
            <strong>Salix Prompt Atlas</strong>
            <span>Source-aware prompt editor</span>
          </div>
        </div>
        <div className="topbar-metrics tabular">
          <span>{totals.documents.toLocaleString()} documents</span>
          <span>{totals.lines.toLocaleString()} elements</span>
          <span>{totals.characters.toLocaleString()} chars</span>
          <span>{totals.words.toLocaleString()} words</span>
          {totals.delta !== 0 ? (
            <span className={totals.delta > 0 ? "delta-positive" : "delta-negative"}>
              {totals.delta > 0 ? "+" : ""}
              {totals.delta} draft chars
            </span>
          ) : null}
        </div>
        <div className="topbar-actions">
          <button
            className={`toggle-button${duplicatesOnly ? " toggle-button--active" : ""}`}
            type="button"
            aria-pressed={duplicatesOnly}
            onClick={() => setDuplicatesOnly((value) => !value)}
          >
            仅重复 · {duplicatesByText.size}
          </button>
          {draftCount ? (
            <button className="secondary-button" type="button" onClick={clearDrafts} disabled={busy}>
              清空草稿 · {draftCount}
            </button>
          ) : null}
          <button
            className="secondary-button"
            type="button"
            onClick={extract}
            disabled={busy || !api?.codexAvailable}
            title={draftCount > 0 ? "清空草稿后才能提取" : "调用 Codex 全量提取"}
          >
            全量提取
          </button>
          <button
            className="primary-button"
            type="button"
            onClick={saveAndApply}
            disabled={busy || draftCount === 0 || !api?.codexAvailable}
          >
            Save &amp; Apply · {draftCount}
          </button>
        </div>
      </header>

      {error ? <ErrorBanner message={error} onClose={() => setError(null)} /> : null}
      <JobPanel job={job} />

      <div className="workspace">
        <aside className="catalog-sidebar">
          <div className="sidebar-heading">
            <span>Prompt catalog</span>
            <strong>{catalog.documents.length}</strong>
          </div>
          <nav aria-label="Prompt 目录">
            {categoryOrder.map((category) => {
              const documents = categoryDocuments.get(category) ?? [];
              return (
                <section key={category}>
                  <div className="nav-category">
                    <span>{categoryLabels[category]}</span>
                    <span>{documents.length}</span>
                  </div>
                  {category === "system"
                    ? promptStages
                        .filter((stage) => stage.category === "system")
                        .map((stage) => (
                          <div className="nav-stage" key={stage.id}>
                            <a
                              className="nav-stage__label"
                              href={`#${promptStageAnchor(stage.id)}`}
                            >
                              <span>{stage.shortLabel}</span>
                              <span>{stage.documents.length}</span>
                            </a>
                            {stage.documents.map((item) => (
                              <a
                                key={`${stage.id}:${item.id}`}
                                href={`#${domId(
                                  "document",
                                  stageDocumentId(stage, item, canonicalStageByDocument),
                                )}`}
                                className={
                                  drafts[item.id] ? "nav-link nav-link--draft" : "nav-link"
                                }
                              >
                                <span>{item.title}</span>
                                {drafts[item.id] ? <i>草稿</i> : null}
                              </a>
                            ))}
                          </div>
                        ))
                    : documents.map((item) => (
                        <a
                          key={item.id}
                          href={`#${domId("document", item.id)}`}
                          className={drafts[item.id] ? "nav-link nav-link--draft" : "nav-link"}
                        >
                          <span>{item.title}</span>
                          {drafts[item.id] ? <i>草稿</i> : null}
                        </a>
                      ))}
                </section>
              );
            })}
          </nav>
        </aside>

        <main className="catalog-content">
          {catalog.documents.length === 0 ? (
            <section className="empty-catalog">
              <div className="empty-catalog__mark">01</div>
              <h1>静态 Prompt 数据尚未提取</h1>
              <p>
                点击“全量提取”，Bun 会启动固定的 Codex 任务，生成 System Prompt、Tool 和
                Skill 的逐行目录、Codex 仓库解释与源码定位。
              </p>
              <button
                className="primary-button"
                type="button"
                onClick={extract}
                disabled={busy || !api?.codexAvailable}
              >
                开始全量提取
              </button>
            </section>
          ) : (
            <>
              <PromptMap stages={promptMapStages} />
              {categoryOrder.map((category) => {
              const documents = categoryDocuments.get(category) ?? [];
              if (!documents.length) return null;
              const categoryLineCount = documents.reduce(
                (sum, item) => sum + effectiveLines(item, drafts).length,
                0,
              );
              return (
                <section
                  className="category-section"
                  key={category}
                  id={
                    category === "tool"
                      ? promptStageAnchor("tools")
                      : category === "skill"
                        ? promptStageAnchor("skills")
                        : undefined
                  }
                >
                  <header className="category-header">
                    <div>
                      <span>Catalog group</span>
                      <h1>{categoryLabels[category]}</h1>
                    </div>
                    <div className="category-header__count tabular">
                      {documents.length} documents · {categoryLineCount.toLocaleString()} elements
                    </div>
                  </header>
                  {category === "system"
                    ? promptStages
                        .filter((stage) => stage.category === "system")
                        .map((stage: PromptStage, stageIndex) => (
                          <section
                            className="prompt-stage"
                            id={promptStageAnchor(stage.id)}
                            key={stage.id}
                          >
                            <header className="prompt-stage__header">
                              <span className="tabular">
                                {String(stageIndex + 1).padStart(2, "0")}
                              </span>
                              <div>
                                <h2>{stage.label}</h2>
                                <p>{stage.description}</p>
                              </div>
                              <strong className="tabular">{stage.documents.length} modules</strong>
                            </header>
                            {stage.documents.map((item) => (
                              <DocumentSection
                                key={`${stage.id}:${item.id}`}
                                document={item}
                                instanceId={stageDocumentId(
                                  stage,
                                  item,
                                  canonicalStageByDocument,
                                )}
                                compositionLabel={promptCompositionLabel(stage.id, item)}
                                explanationContext={`${stage.label} · ${promptCompositionLabel(stage.id, item) ?? item.title}`}
                                draft={drafts[item.id]}
                                duplicatesByText={duplicatesByText}
                                duplicatesOnly={duplicatesOnly}
                                onChange={changeDocument}
                                onExplain={explainLine}
                                onJumpDuplicate={jumpDuplicate}
                              />
                            ))}
                          </section>
                        ))
                    : documents.map((item) => (
                        <DocumentSection
                          key={item.id}
                          document={item}
                          explanationContext={`${categoryLabels[category]} · ${item.title}`}
                          draft={drafts[item.id]}
                          duplicatesByText={duplicatesByText}
                          duplicatesOnly={duplicatesOnly}
                          onChange={changeDocument}
                          onExplain={explainLine}
                          onJumpDuplicate={jumpDuplicate}
                        />
                      ))}
                </section>
              );
              })}
            </>
          )}
        </main>
      </div>
    </div>
  );
}
