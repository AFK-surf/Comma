import { ScrollArea, ScrollAreaLoadMore, SearchIcon } from "@comma/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import type { BftSwarm, BftSwarmsPage } from "./api";
import { formatRelative } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { FormDialog, TextField, useWrite } from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.swarms;

/** The slug the server derives from a name, shown until the slug is edited. */
export const slugify = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

interface Listing {
  rows: BftSwarm[] | undefined;
  viewer: BftSwarmsPage["viewer"] | undefined;
  cursor: string | null;
  loading: boolean;
  failed: boolean;
}

/** Pages of Agent Swarms matching `query`; a new query starts over. */
function useSwarms(org: string, query: string) {
  const api = useApi();
  const [listing, setListing] = useState<Listing>({
    rows: undefined,
    viewer: undefined,
    cursor: null,
    loading: true,
    failed: false,
  });
  const controller = useRef<AbortController | null>(null);

  const fetchPage = useCallback(
    (after: string | null) => {
      const abort = new AbortController();
      controller.current?.abort();
      controller.current = abort;
      setListing((previous) => ({ ...previous, loading: true, failed: false }));
      api.swarms(org, query, after, abort.signal).then(
        (page) => {
          if (abort.signal.aborted) return;
          setListing((previous) => {
            const known = after ? (previous.rows ?? []) : [];
            const seen = new Set(known.map((row) => row.id));
            return {
              rows: [...known, ...page.projects.filter((row) => !seen.has(row.id))],
              viewer: page.viewer,
              cursor: page.next_cursor,
              loading: false,
              failed: false,
            };
          });
        },
        () => {
          if (abort.signal.aborted) return;
          setListing((previous) => ({ ...previous, loading: false, failed: true }));
        }
      );
    },
    [api, org, query]
  );

  useEffect(() => {
    setListing((previous) => ({ ...previous, rows: undefined, cursor: null }));
    fetchPage(null);
    return () => controller.current?.abort();
  }, [fetchPage]);

  return { ...listing, fetchPage };
}

const statusTone = (status: string) =>
  status === "active" ? "ok" : status === "archived" ? undefined : "warn";

export function SwarmsPage({
  org,
  orgName,
}: {
  org: string;
  orgName: string | undefined;
}) {
  const [filter, setFilter] = useState("");
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(() => setQuery(filter.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [filter]);

  const swarms = useSwarms(org, query);
  const { rows, cursor, loading, failed } = swarms;
  const loadMore = () => {
    if (cursor && !loading) swarms.fetchPage(cursor);
  };

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {swarms.viewer?.can_create ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => setCreating(true)}
              type="button"
            >
              {t.create}
            </button>
          ) : null}
        </div>
      </div>
      <section aria-labelledby="bft-swarms-title" className="bft-panel bft-panel-table">
        <div className="bft-panel-header">
          <h2 id="bft-swarms-title">{t.listTitle}</h2>
          <label className="bft-filter">
            <SearchIcon className="bft-filter-icon" />
            <input
              aria-label={t.filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder={t.filter}
              type="search"
              value={filter}
            />
          </label>
        </div>
        {!rows ? (
          failed ? (
            <ErrorState onRetry={() => swarms.fetchPage(null)} />
          ) : (
            <div className="bft-rows-skeleton">
              {Array.from({ length: 5 }, (_, index) => (
                <Skeleton height={14} key={index} />
              ))}
            </div>
          )
        ) : rows.length === 0 ? (
          <p className="bft-quiet">{query ? t.noMatches : t.empty}</p>
        ) : (
          <ScrollArea
            className="bft-panel-scroll"
            edgeEffect="none"
            orientation="vertical"
            scrollbarVisibility="hover"
            viewportClassName="bft-scroll-viewport"
          >
            <table className="bft-table bft-swarms">
              <thead>
                <tr>
                  <th scope="col">{t.columnName}</th>
                  <th className="bft-col-slug" scope="col">
                    {t.columnSlug}
                  </th>
                  <th className="bft-col-runtime-id" scope="col">
                    {t.columnRuntime}
                  </th>
                  <th className="bft-col-status" scope="col">
                    {t.columnStatus}
                  </th>
                  <th className="bft-col-refreshed" scope="col">
                    {t.columnCreated}
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((swarm) => (
                  <tr key={swarm.id}>
                    <td>
                      <a
                        className="bft-link"
                        href={projectHref(org, swarm.id)}
                        onClick={spaLinkClick}
                        title={swarm.name}
                      >
                        {swarm.name}
                      </a>
                    </td>
                    <td className="bft-col-slug" title={swarm.slug ?? undefined}>
                      {swarm.slug ?? "—"}
                    </td>
                    <td
                      className="bft-col-runtime-id"
                      title={swarm.salix_group_id ?? undefined}
                    >
                      {swarm.salix_group_id ?? "—"}
                    </td>
                    <td className="bft-col-status">
                      <span className="bft-status" data-tone={statusTone(swarm.status)}>
                        {messages.project.states[swarm.status] ?? swarm.status}
                      </span>
                    </td>
                    <td
                      className="bft-col-refreshed"
                      title={swarm.created_at ?? undefined}
                    >
                      {swarm.created_at
                        ? (formatRelative(swarm.created_at) ?? "—")
                        : "—"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <ScrollAreaLoadMore
              failed={failed}
              hasMore={cursor !== null}
              loading={loading}
              onLoadMore={loadMore}
              quiet
            />
            {loading ? (
              <output className="bft-quiet">{t.loadingMore}</output>
            ) : failed ? (
              <div className="bft-quiet-row" role="alert">
                <p className="bft-quiet bft-quiet-inline">{t.loadMoreFailed}</p>
                <button className="bft-btn bft-btn-sm" onClick={loadMore} type="button">
                  {messages.states.retry}
                </button>
              </div>
            ) : null}
          </ScrollArea>
        )}
      </section>
      {creating ? (
        <CreateSwarmDialog onClose={() => setCreating(false)} org={org} />
      ) : null}
    </div>
  );
}

function CreateSwarmDialog({ org, onClose }: { org: string; onClose: () => void }) {
  const api = useApi();
  const write = useWrite();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState<string>();
  const [nameMissing, setNameMissing] = useState(false);

  const submit = () => {
    if (!name.trim()) {
      setNameMissing(true);
      return;
    }
    setNameMissing(false);
    write.run(
      () =>
        api.createSwarm(org, {
          name: name.trim(),
          slug: (slug ?? slugify(name)).trim(),
        }),
      (swarm) => navigate(projectHref(org, swarm.id))
    );
  };

  return (
    <FormDialog
      description={t.createBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={submit}
      submitLabel={t.createConfirm}
      title={t.create}
      write={{
        ...write,
        error: write.fields.name || write.fields.slug ? undefined : write.error,
      }}
    >
      <TextField
        disabled={write.busy}
        error={nameMissing ? t.nameRequired : write.fields.name}
        label={t.nameLabel}
        onChange={setName}
        placeholder={t.namePlaceholder}
        value={name}
      />
      <TextField
        disabled={write.busy}
        error={write.fields.slug}
        hint={t.slugHint}
        label={t.slugLabel}
        onChange={setSlug}
        value={slug ?? slugify(name)}
      />
    </FormDialog>
  );
}
