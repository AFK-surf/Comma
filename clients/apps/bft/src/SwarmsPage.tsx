import { Dropdown } from "@comma/ui/components/dropdown";
import { SearchIcon } from "@comma/ui/components/icons";
import { ScrollArea, ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import {
  Fragment,
  type ReactNode,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import type {
  BftCatalogSwarm,
  BftDepartment,
  BftSearchTargetInput,
  BftSwarm,
  BftSwarmsPage,
} from "./api";
import { formatInteger, formatRelative } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { formatTargetSummary, SearchTargetPicker } from "./SearchTargetPicker";
import { FormDialog, TextField, useConfirm, useWrite } from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.swarms;
const unassignedOptionId = "__unassigned__";

/** The slug the server derives from a name, shown until the slug is edited. */
export const slugify = (name: string) =>
  name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

interface Listing {
  rows: BftSwarm[] | undefined;
  departments: BftDepartment[];
  catalogSwarms: BftCatalogSwarm[];
  departmentCounts: Record<string, number>;
  unassignedCount: number | null;
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
    departments: [],
    catalogSwarms: [],
    departmentCounts: {},
    unassignedCount: null,
    viewer: undefined,
    cursor: null,
    loading: true,
    failed: false,
  });
  const controller = useRef<AbortController | null>(null);

  const applyPage = useCallback((page: BftSwarmsPage) => {
    setListing({
      rows: page.projects,
      departments: page.departments,
      catalogSwarms: page.catalog_swarms,
      departmentCounts: page.department_counts,
      unassignedCount: page.unassigned_count,
      viewer: page.viewer,
      cursor: page.next_cursor,
      loading: false,
      failed: false,
    });
  }, []);

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
              departments: page.departments,
              catalogSwarms: page.catalog_swarms,
              departmentCounts: page.department_counts,
              unassignedCount: page.unassigned_count,
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

  return { ...listing, fetchPage, applyPage };
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
  const [deptDialog, setDeptDialog] = useState<"create" | BftDepartment | null>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => setQuery(filter.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [filter]);

  const swarms = useSwarms(org, query);
  const {
    rows,
    departments,
    catalogSwarms,
    departmentCounts,
    unassignedCount,
    viewer,
    cursor,
    loading,
    failed,
  } = swarms;
  const canManageDepts = Boolean(viewer?.can_manage_departments);
  const loadMore = () => {
    if (cursor && !loading) swarms.fetchPage(cursor);
  };

  const grouped =
    departments.length > 0 ||
    Boolean(rows?.some((row) => row.extra_targets.length > 0));
  // Only organization owners and admins see search rules.
  const showSearchCol = grouped && canManageDepts;
  const needle = query.toLowerCase();

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {canManageDepts ? (
            <button
              className="bft-btn"
              onClick={() => setDeptDialog("create")}
              type="button"
            >
              {t.newDepartment}
            </button>
          ) : null}
          {viewer?.can_create ? (
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
        ) : rows.length === 0 &&
          (query || departments.length === 0 || !canManageDepts) ? (
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
                  {showSearchCol ? (
                    <th className="bft-col-search" scope="col">
                      {t.columnSearch}
                    </th>
                  ) : null}
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
                {grouped ? (
                  <GroupedSwarmRows
                    canManageDepts={canManageDepts}
                    departmentCounts={departmentCounts}
                    departments={departments}
                    hasMore={cursor !== null}
                    needle={needle}
                    onEditDepartment={setDeptDialog}
                    org={org}
                    rows={rows}
                    showSearchCol={showSearchCol}
                    unassignedCount={unassignedCount}
                  />
                ) : (
                  rows.map((swarm) => (
                    <SwarmRow
                      indented={false}
                      showSearchCol={false}
                      key={swarm.id}
                      org={org}
                      swarm={swarm}
                    />
                  ))
                )}
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
        <CreateSwarmDialog
          departments={canManageDepts ? departments : []}
          onClose={() => setCreating(false)}
          org={org}
        />
      ) : null}
      {deptDialog ? (
        <DepartmentDialog
          catalogSwarms={catalogSwarms}
          department={deptDialog === "create" ? null : deptDialog}
          departments={departments}
          onClose={() => setDeptDialog(null)}
          onSaved={(page) => {
            swarms.applyPage(page);
            setDeptDialog(null);
          }}
          org={org}
          query={query}
        />
      ) : null}
    </div>
  );
}

/** Departments in the server's page order: by name, case-insensitively. */
const departmentOrder = (a: BftDepartment, b: BftDepartment) => {
  const left = a.name.toLowerCase();
  const right = b.name.toLowerCase();
  return left < right ? -1 : left > right ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
};

function GroupedSwarmRows({
  org,
  rows,
  departments,
  departmentCounts,
  unassignedCount,
  hasMore,
  canManageDepts,
  showSearchCol,
  needle,
  onEditDepartment,
}: {
  org: string;
  rows: BftSwarm[];
  departments: BftDepartment[];
  departmentCounts: Record<string, number>;
  unassignedCount: number | null;
  hasMore: boolean;
  canManageDepts: boolean;
  showSearchCol: boolean;
  needle: string;
  onEditDepartment: (dept: BftDepartment) => void;
}) {
  const deptIdSet = new Set(departments.map((dept) => dept.id));
  const unassigned = rows.filter(
    (row) => !row.department_id || !deptIdSet.has(row.department_id)
  );
  const ordered = departments.toSorted(departmentOrder);
  // While more pages remain, a department after the last loaded Swarm's
  // department is not reached yet: its heading waits for its page, so loading
  // more only appends below what is shown.
  const lastRow = rows.at(-1);
  const lastDept =
    lastRow?.department_id && deptIdSet.has(lastRow.department_id)
      ? departments.find((dept) => dept.id === lastRow.department_id)
      : undefined;
  const reached = (dept: BftDepartment) =>
    !hasMore ||
    (lastRow !== undefined && lastDept === undefined) ||
    (lastDept !== undefined && departmentOrder(dept, lastDept) <= 0);

  return (
    <>
      {ordered.map((dept) => {
        const members = rows.filter((row) => row.department_id === dept.id);
        const visible =
          members.length > 0 ||
          (reached(dept) &&
            canManageDepts &&
            (!needle || dept.name.toLowerCase().includes(needle)));
        if (!visible) return null;
        const summary = formatTargetSummary(dept.targets);
        return (
          <Fragment key={dept.id}>
            <DepartmentRow
              actions={
                canManageDepts ? (
                  <button
                    aria-label={t.editDepartmentFor(dept.name)}
                    className="bft-btn bft-btn-sm"
                    onClick={() => onEditDepartment(dept)}
                    type="button"
                  >
                    {t.editDepartment}
                  </button>
                ) : null
              }
              count={departmentCounts[dept.id] ?? members.length}
              name={dept.name}
              showSearchCol={showSearchCol}
              summary={summary}
            />
            {members.map((swarm) => (
              <SwarmRow
                indented
                key={swarm.id}
                org={org}
                showSearchCol={showSearchCol}
                swarm={swarm}
              />
            ))}
          </Fragment>
        );
      })}
      {unassigned.length > 0 ? (
        <Fragment>
          <DepartmentRow
            actions={null}
            count={unassignedCount ?? unassigned.length}
            name={t.unassigned}
            showSearchCol={showSearchCol}
            summary=""
          />
          {unassigned.map((swarm) => (
            <SwarmRow
              indented
              key={swarm.id}
              org={org}
              showSearchCol={showSearchCol}
              swarm={swarm}
            />
          ))}
        </Fragment>
      ) : null}
    </>
  );
}

/**
 * A department heading row with one cell per table column, so a column the
 * container hides (slug, search, runtime id, created) goes from the heading row
 * too and every row keeps the header's columns.
 */
function DepartmentRow({
  name,
  count,
  summary,
  showSearchCol,
  actions,
}: {
  name: string;
  count: number;
  summary: string;
  showSearchCol: boolean;
  actions: ReactNode;
}) {
  return (
    <tr className="bft-group-row bft-dept-row">
      <th aria-label={name} scope="colgroup">
        <span className="bft-dept-heading">
          <span className="bft-truncate" title={name}>
            {name}
          </span>
          <span className="bft-count">{formatInteger(count)}</span>
        </span>
      </th>
      <td aria-hidden="true" className="bft-col-slug" />
      {showSearchCol ? (
        <td className="bft-col-search" title={summary || undefined}>
          {summary || "—"}
        </td>
      ) : null}
      <td aria-hidden="true" className="bft-col-runtime-id" />
      {/* Status and created: one cell over both, or the status cell alone where
          the container hides the created column. */}
      <td className="bft-dept-actions bft-dept-actions-wide" colSpan={2}>
        {actions ?? "\u00a0"}
      </td>
      <td className="bft-dept-actions bft-dept-actions-narrow">
        {actions ?? "\u00a0"}
      </td>
    </tr>
  );
}

function SwarmRow({
  org,
  swarm,
  showSearchCol,
  indented,
}: {
  org: string;
  swarm: BftSwarm;
  showSearchCol: boolean;
  indented: boolean;
}) {
  const extra =
    swarm.extra_targets.length > 0
      ? t.extraPrefix(formatTargetSummary(swarm.extra_targets))
      : "";
  return (
    <tr>
      <td>
        <a
          className={indented ? "bft-link bft-dept-member-link" : "bft-link"}
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
      {showSearchCol ? (
        <td
          aria-label={extra || "—"}
          className="bft-col-search"
          title={extra || undefined}
        >
          {extra ? <span className="bft-search-extra">{extra}</span> : "\u00a0"}
        </td>
      ) : null}
      <td className="bft-col-runtime-id" title={swarm.salix_group_id ?? undefined}>
        {swarm.salix_group_id ?? "—"}
      </td>
      <td className="bft-col-status">
        <span className="bft-status" data-tone={statusTone(swarm.status)}>
          {messages.project.states[swarm.status] ?? swarm.status}
        </span>
      </td>
      <td className="bft-col-refreshed" title={swarm.created_at ?? undefined}>
        {swarm.created_at ? (formatRelative(swarm.created_at) ?? "—") : "—"}
      </td>
    </tr>
  );
}

function CreateSwarmDialog({
  org,
  departments,
  onClose,
}: {
  org: string;
  departments: BftDepartment[];
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState<string>();
  const [departmentId, setDepartmentId] = useState(unassignedOptionId);
  const [nameMissing, setNameMissing] = useState(false);

  const submit = () => {
    if (!name.trim()) {
      setNameMissing(true);
      return;
    }
    setNameMissing(false);
    const chosenDept = departmentId === unassignedOptionId ? undefined : departmentId;
    write.run(
      () =>
        api.createSwarm(org, {
          name: name.trim(),
          slug: (slug ?? slugify(name)).trim(),
          ...(chosenDept ? { department_id: chosenDept } : {}),
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
      {departments.length > 0 ? (
        <Dropdown
          className="bft-form-field"
          disabled={write.busy}
          items={[
            { id: unassignedOptionId, label: t.unassigned },
            ...departments.map((dept) => ({ id: dept.id, label: dept.name })),
          ]}
          label={t.departmentLabel}
          onChange={setDepartmentId}
          size="sm"
          value={departmentId}
        />
      ) : null}
    </FormDialog>
  );
}

function DepartmentDialog({
  org,
  department,
  departments,
  catalogSwarms,
  onSaved,
  onClose,
  query,
}: {
  org: string;
  query: string;
  department: BftDepartment | null;
  departments: BftDepartment[];
  catalogSwarms: BftCatalogSwarm[];
  onSaved: (page: BftSwarmsPage) => void;
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const confirm = useConfirm();
  const [name, setName] = useState(department?.name ?? "");
  const [targets, setTargets] = useState<BftSearchTargetInput[]>(() =>
    (department?.targets ?? []).map((target) =>
      target.kind === "self" || target.kind === "all_departments"
        ? { kind: target.kind }
        : { kind: target.kind, id: target.id }
    )
  );
  const [nameMissing, setNameMissing] = useState(false);

  const submit = () => {
    if (!name.trim()) {
      setNameMissing(true);
      return;
    }
    setNameMissing(false);
    const body = { name: name.trim(), targets };
    write.run(
      () =>
        department
          ? api.updateDepartment(org, department.id, body, query)
          : api.createDepartment(org, body, query),
      onSaved
    );
  };

  return (
    <>
      <FormDialog
        description={t.departmentDialogBody}
        onClose={() => {
          if (!write.busy) onClose();
        }}
        onSubmit={submit}
        submitLabel={department ? t.departmentSaveConfirm : t.departmentCreateConfirm}
        title={
          department ? t.departmentEditTitle(department.name) : t.departmentCreateTitle
        }
        write={{
          ...write,
          error: write.fields.name ? undefined : write.error,
        }}
      >
        <TextField
          disabled={write.busy}
          error={nameMissing ? t.departmentNameRequired : write.fields.name}
          label={t.departmentNameLabel}
          onChange={setName}
          placeholder={t.departmentNamePlaceholder}
          value={name}
        />
        <div className="bft-form-field">
          <p className="bft-field-label">{t.searchScopeLabel}</p>
          <SearchTargetPicker
            catalogSwarms={catalogSwarms}
            departments={departments.map(({ id, name: deptName }) => ({
              id,
              name: deptName,
            }))}
            disabled={write.busy}
            {...(department ? { excludeDepartmentId: department.id } : {})}
            offerSelfDepartment
            onChange={setTargets}
            searcherIfcOff={
              department
                ? catalogSwarms.some(
                    (swarm) => swarm.department_id === department.id && !swarm.ifc_on
                  )
                : false
            }
            value={targets}
          />
        </div>
        {department ? (
          <div className="bft-dept-dialog-delete">
            <button
              className="bft-link-button bft-link-danger"
              disabled={write.busy}
              onClick={() =>
                confirm.ask({
                  title: t.departmentDeleteTitle,
                  description: t.departmentDeleteBody(department.name),
                  confirmLabel: t.departmentDelete,
                  action: () =>
                    api.deleteDepartment(org, department.id, query).then(onSaved),
                })
              }
              type="button"
            >
              {t.departmentDelete}
            </button>
          </div>
        ) : null}
      </FormDialog>
      {confirm.dialog}
    </>
  );
}
