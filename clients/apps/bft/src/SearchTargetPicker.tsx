import { Checkbox } from "@comma/ui/components/checkbox";
import { ChevronRightSmallIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useId, useMemo, useState } from "react";
import type { BftCatalogSwarm, BftSearchTarget, BftSearchTargetInput } from "./api";
import { messages } from "./messages";

const t = messages.swarms;

export const formatTargetSummary = (targets: BftSearchTarget[]): string =>
  targets
    .map((target) =>
      target.kind === "all_departments"
        ? t.allDepartmentsLabel
        : target.kind === "self"
          ? t.selfDepartmentLabel
          : target.name
    )
    .join(t.targetListSeparator);

export const targetInputKey = (target: BftSearchTargetInput): string =>
  target.kind === "self" || target.kind === "all_departments"
    ? target.kind
    : `${target.kind}:${target.id ?? ""}`;

export const sameTargetInputs = (
  left: BftSearchTargetInput[],
  right: BftSearchTargetInput[]
): boolean => {
  const a = [...new Set(left.map(targetInputKey))].toSorted();
  const b = [...new Set(right.map(targetInputKey))].toSorted();
  return a.length === b.length && a.every((key, index) => key === b[index]);
};

/**
 * The line under one Swarm of the picker: inherited, and whether the
 * searching side cannot reach it because it has IFC on and that side not.
 */
const memberHint = (
  swarm: BftCatalogSwarm,
  inherited: boolean,
  searcherIfcOff: boolean
): string | undefined => {
  const parts = [
    inherited ? messages.swarmSettings.inheritedBadge : null,
    searcherIfcOff && swarm.ifc_on ? t.ifcTargetHint : null,
  ].filter((part): part is string => part !== null);
  return parts.length > 0 ? parts.join(" · ") : undefined;
};

export function SearchTargetPicker({
  departments,
  catalogSwarms,
  value,
  onChange,
  offerSelfDepartment = false,
  excludeDepartmentId,
  inheritedDepartmentId,
  inheritedTargets = [],
  searcherIfcOff = false,
  disabled = false,
}: {
  departments: { id: string; name: string }[];
  catalogSwarms: BftCatalogSwarm[];
  value: BftSearchTargetInput[];
  onChange: (next: BftSearchTargetInput[]) => void;
  offerSelfDepartment?: boolean;
  excludeDepartmentId?: string;
  inheritedDepartmentId?: string | null;
  inheritedTargets?: BftSearchTarget[];
  /** A searching Swarm has IFC off, so it cannot search the Swarms that have it on. */
  searcherIfcOff?: boolean;
  disabled?: boolean;
}) {
  const [query, setQuery] = useState("");
  const needle = query.trim().toLowerCase();
  const searching = needle.length > 0;

  const allDeptsSelected = value.some((item) => item.kind === "all_departments");
  const allDeptsInherited = inheritedTargets.some(
    (item) => item.kind === "all_departments"
  );
  const allDeptsActive = allDeptsSelected || allDeptsInherited;
  const selfSelected = value.some((item) => item.kind === "self");
  const explicitDeptIds = useMemo(
    () =>
      new Set(
        value.flatMap((item) =>
          item.kind === "department" && item.id ? [item.id] : []
        )
      ),
    [value]
  );
  const explicitProjIds = useMemo(
    () =>
      new Set(
        value.flatMap((item) => (item.kind === "project" && item.id ? [item.id] : []))
      ),
    [value]
  );

  const inheritedDeptIds = useMemo(() => {
    const ids = new Set<string>();
    for (const item of inheritedTargets) {
      if (item.kind === "self" && inheritedDepartmentId) {
        ids.add(inheritedDepartmentId);
      } else if (item.kind === "department") {
        ids.add(item.id);
      }
    }
    return ids;
  }, [inheritedDepartmentId, inheritedTargets]);

  const inheritedProjIds = useMemo(
    () =>
      new Set(
        inheritedTargets.flatMap((item) => (item.kind === "project" ? [item.id] : []))
      ),
    [inheritedTargets]
  );

  const peerDepartments = useMemo(
    () => departments.filter((dept) => dept.id !== excludeDepartmentId),
    [departments, excludeDepartmentId]
  );

  const allUnassigned = useMemo(
    () => catalogSwarms.filter((swarm) => !swarm.department_id),
    [catalogSwarms]
  );
  const unassignedSwarms = useMemo(
    () =>
      allUnassigned.filter(
        (swarm) => !searching || swarm.name.toLowerCase().includes(needle)
      ),
    [allUnassigned, needle, searching]
  );

  const shownDepartments = useMemo(
    () =>
      peerDepartments.flatMap((dept) => {
        const allMembers = catalogSwarms.filter(
          (swarm) => swarm.department_id === dept.id
        );
        const deptMatches = !searching || dept.name.toLowerCase().includes(needle);
        const members =
          !searching || deptMatches
            ? allMembers
            : allMembers.filter((swarm) => swarm.name.toLowerCase().includes(needle));
        if (searching && !deptMatches && members.length === 0) return [];
        return [{ dept, allMembers, members }];
      }),
    [catalogSwarms, needle, peerDepartments, searching]
  );

  const toggleAllDepartments = (checked: boolean) => {
    if (checked) {
      const assignedProjIds = new Set(
        catalogSwarms
          .filter((swarm) => Boolean(swarm.department_id))
          .map((swarm) => swarm.id)
      );
      const rest = value.filter(
        (item) =>
          item.kind !== "all_departments" &&
          item.kind !== "self" &&
          item.kind !== "department" &&
          !(item.kind === "project" && item.id && assignedProjIds.has(item.id))
      );
      onChange([{ kind: "all_departments" }, ...rest]);
    } else {
      onChange(value.filter((item) => item.kind !== "all_departments"));
    }
  };

  const toggleSelf = (checked: boolean) => {
    const rest = value.filter((item) => item.kind !== "self");
    onChange(checked ? [{ kind: "self" }, ...rest] : rest);
  };

  const toggleDepartment = (
    deptId: string,
    allMembers: BftCatalogSwarm[],
    checked: boolean
  ) => {
    const memberIds = new Set(allMembers.map((swarm) => swarm.id));
    const cleaned = value.filter(
      (item) =>
        !(item.kind === "department" && item.id === deptId) &&
        !(item.kind === "project" && item.id && memberIds.has(item.id))
    );
    onChange(checked ? [...cleaned, { kind: "department", id: deptId }] : cleaned);
  };

  const toggleProject = (
    swarmId: string,
    deptId: string | null,
    deptMembers: BftCatalogSwarm[],
    checked: boolean
  ) => {
    if (deptId && explicitDeptIds.has(deptId) && !checked) {
      const remaining = deptMembers
        .filter((member) => member.id !== swarmId && !inheritedProjIds.has(member.id))
        .map(
          (member): BftSearchTargetInput => ({
            kind: "project",
            id: member.id,
          })
        );
      const rest = value.filter(
        (item) => !(item.kind === "department" && item.id === deptId)
      );
      onChange([...rest, ...remaining]);
      return;
    }

    const rest = value.filter(
      (item) => !(item.kind === "project" && item.id === swarmId)
    );
    onChange(checked ? [...rest, { kind: "project", id: swarmId }] : rest);
  };

  /** Select or clear every unassigned Swarm that is not already inherited. */
  const toggleUnassigned = (checked: boolean) => {
    const ids = new Set(
      allUnassigned
        .filter((swarm) => !inheritedProjIds.has(swarm.id))
        .map((swarm) => swarm.id)
    );
    const rest = value.filter(
      (item) => !(item.kind === "project" && item.id && ids.has(item.id))
    );
    onChange(
      checked
        ? [
            ...rest,
            ...[...ids].map((id): BftSearchTargetInput => ({ kind: "project", id })),
          ]
        : rest
    );
  };

  const hasAnyCatalog =
    offerSelfDepartment ||
    peerDepartments.length > 0 ||
    catalogSwarms.some((swarm) => !swarm.department_id);

  if (!hasAnyCatalog) {
    return <p className="bft-quiet bft-quiet-inline">{t.searchNoTargets}</p>;
  }

  const showFilter = peerDepartments.length + catalogSwarms.length > 4 || searching;

  return (
    <div className="bft-model-picker bft-search-picker">
      <div className="bft-search-scope-options">
        <Checkbox
          checked={allDeptsActive}
          disabled={disabled || allDeptsInherited}
          hint={
            allDeptsInherited
              ? messages.swarmSettings.inheritedBadge
              : t.allDepartmentsHint
          }
          label={t.allDepartmentsLabel}
          onChange={(event) => toggleAllDepartments(event.target.checked)}
          size="sm"
        />
        {offerSelfDepartment ? (
          <Checkbox
            checked={allDeptsActive || selfSelected}
            disabled={disabled || allDeptsActive}
            hint={t.selfDepartmentHint}
            label={t.selfDepartmentLabel}
            onChange={(event) => toggleSelf(event.target.checked)}
            size="sm"
          />
        ) : null}
      </div>
      {showFilter ? (
        <InputField
          aria-label={t.searchFilterHint}
          autoComplete="off"
          className="w-full"
          disabled={disabled}
          fieldSize="sm"
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t.searchFilterHint}
          type="search"
          value={query}
          wrapperClassName="bft-model-filter"
        />
      ) : null}
      {searching && shownDepartments.length === 0 && unassignedSwarms.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.searchNoMatches}</p>
      ) : null}
      {shownDepartments.map(({ dept, allMembers, members }) => (
        <DepartmentTargetGroup
          allMembers={allMembers}
          coveredByAllDepartments={allDeptsSelected && !allDeptsInherited}
          dept={dept}
          deptInherited={allDeptsInherited || inheritedDeptIds.has(dept.id)}
          deptSelected={explicitDeptIds.has(dept.id)}
          disabled={disabled}
          explicitProjIds={explicitProjIds}
          forcedOpen={searching ? true : undefined}
          inheritedProjIds={inheritedProjIds}
          key={dept.id}
          members={members}
          onToggleDepartment={(checked) =>
            toggleDepartment(dept.id, allMembers, checked)
          }
          onToggleMember={(swarmId, checked) =>
            toggleProject(swarmId, dept.id, allMembers, checked)
          }
          searcherIfcOff={searcherIfcOff}
        />
      ))}
      {unassignedSwarms.length > 0 ? (
        <UnassignedTargetGroup
          allSwarms={allUnassigned}
          disabled={disabled}
          explicitProjIds={explicitProjIds}
          forcedOpen={searching ? true : undefined}
          inheritedProjIds={inheritedProjIds}
          onToggleAll={toggleUnassigned}
          onToggleMember={(swarmId, checked) =>
            toggleProject(swarmId, null, [], checked)
          }
          searcherIfcOff={searcherIfcOff}
          swarms={unassignedSwarms}
        />
      ) : null}
    </div>
  );
}

function DepartmentTargetGroup({
  dept,
  allMembers,
  members,
  coveredByAllDepartments,
  deptInherited,
  deptSelected,
  explicitProjIds,
  inheritedProjIds,
  disabled,
  forcedOpen,
  onToggleDepartment,
  onToggleMember,
  searcherIfcOff,
}: {
  dept: { id: string; name: string };
  allMembers: BftCatalogSwarm[];
  members: BftCatalogSwarm[];
  coveredByAllDepartments: boolean;
  deptInherited: boolean;
  deptSelected: boolean;
  explicitProjIds: Set<string>;
  inheritedProjIds: Set<string>;
  disabled: boolean;
  forcedOpen: boolean | undefined;
  onToggleDepartment: (checked: boolean) => void;
  onToggleMember: (swarmId: string, checked: boolean) => void;
  searcherIfcOff: boolean;
}) {
  const hasPartialExplicit =
    !deptSelected && allMembers.some((member) => explicitProjIds.has(member.id));
  const [toggled, setOpen] = useState(hasPartialExplicit);
  const open = forcedOpen ?? toggled;
  const bodyId = useId();

  const selectedCount = allMembers.filter(
    (member) =>
      deptInherited ||
      coveredByAllDepartments ||
      deptSelected ||
      explicitProjIds.has(member.id) ||
      inheritedProjIds.has(member.id)
  ).length;

  const badge = deptInherited
    ? messages.swarmSettings.inheritedBadge
    : coveredByAllDepartments
      ? t.includedByAllDepartments
      : deptSelected
        ? t.wholeDepartment
        : allMembers.length > 0
          ? t.selectedCount(selectedCount, allMembers.length)
          : "";

  return (
    <section className="bft-model-group">
      <div className="bft-model-group-head">
        <Checkbox
          aria-label={t.selectDepartmentAll(dept.name)}
          checked={deptInherited || coveredByAllDepartments || deptSelected}
          disabled={disabled || deptInherited || coveredByAllDepartments}
          indeterminate={
            !deptInherited &&
            !coveredByAllDepartments &&
            !deptSelected &&
            selectedCount > 0
          }
          onChange={(event) => onToggleDepartment(event.target.checked)}
          size="sm"
        />
        {members.length > 0 ? (
          <button
            aria-controls={bodyId}
            aria-expanded={open}
            aria-label={open ? t.collapseGroup(dept.name) : t.expandGroup(dept.name)}
            className="bft-model-group-toggle"
            onClick={() => setOpen(!open)}
            type="button"
          >
            <span
              className="bft-model-group-chevron"
              data-open={open ? true : undefined}
            >
              <ChevronRightSmallIcon />
            </span>
            <span className="bft-model-group-title">{dept.name}</span>
            {badge ? <span className="bft-model-group-count">{badge}</span> : null}
          </button>
        ) : (
          <div className="bft-model-group-static">
            {/* Keeps the name where a chevron puts the names of groups with Swarms. */}
            <span
              aria-hidden="true"
              className="bft-model-group-chevron bft-model-group-chevron-empty"
            >
              <ChevronRightSmallIcon />
            </span>
            <span className="bft-model-group-title">{dept.name}</span>
            {badge ? <span className="bft-model-group-count">{badge}</span> : null}
          </div>
        )}
      </div>
      {open && members.length > 0 ? (
        <ScrollArea
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-model-group-viewport"
        >
          <div className="bft-checklist" id={bodyId}>
            {members.map((member) => {
              const memberInherited = deptInherited || inheritedProjIds.has(member.id);
              const checked =
                memberInherited ||
                coveredByAllDepartments ||
                deptSelected ||
                explicitProjIds.has(member.id);
              const hint = memberHint(member, memberInherited, searcherIfcOff);
              return (
                <Checkbox
                  checked={checked}
                  disabled={disabled || memberInherited || coveredByAllDepartments}
                  {...(hint ? { hint } : {})}
                  key={member.id}
                  label={member.name}
                  onChange={(event) => onToggleMember(member.id, event.target.checked)}
                  size="sm"
                />
              );
            })}
          </div>
        </ScrollArea>
      ) : null}
    </section>
  );
}

function UnassignedTargetGroup({
  swarms,
  allSwarms,
  explicitProjIds,
  inheritedProjIds,
  disabled,
  forcedOpen,
  onToggleAll,
  onToggleMember,
  searcherIfcOff,
}: {
  swarms: BftCatalogSwarm[];
  allSwarms: BftCatalogSwarm[];
  explicitProjIds: Set<string>;
  inheritedProjIds: Set<string>;
  disabled: boolean;
  forcedOpen: boolean | undefined;
  onToggleAll: (checked: boolean) => void;
  onToggleMember: (swarmId: string, checked: boolean) => void;
  searcherIfcOff: boolean;
}) {
  const hasExplicit = allSwarms.some((swarm) => explicitProjIds.has(swarm.id));
  const [toggled, setOpen] = useState(hasExplicit);
  const open = forcedOpen ?? toggled;
  const bodyId = useId();
  const selected = allSwarms.filter(
    (swarm) => explicitProjIds.has(swarm.id) || inheritedProjIds.has(swarm.id)
  ).length;
  const allInherited = allSwarms.every((swarm) => inheritedProjIds.has(swarm.id));

  return (
    <section className="bft-model-group">
      <div className="bft-model-group-head">
        <Checkbox
          aria-label={t.selectDepartmentAll(t.unassigned)}
          checked={selected === allSwarms.length}
          disabled={disabled || allInherited}
          indeterminate={selected > 0 && selected < allSwarms.length}
          onChange={(event) => onToggleAll(event.target.checked)}
          size="sm"
        />
        <button
          aria-controls={bodyId}
          aria-expanded={open}
          aria-label={
            open ? t.collapseGroup(t.unassigned) : t.expandGroup(t.unassigned)
          }
          className="bft-model-group-toggle"
          onClick={() => setOpen(!open)}
          type="button"
        >
          <span className="bft-model-group-chevron" data-open={open ? true : undefined}>
            <ChevronRightSmallIcon />
          </span>
          <span className="bft-model-group-title">{t.unassigned}</span>
          <span className="bft-model-group-count">
            {t.selectedCount(selected, allSwarms.length)}
          </span>
        </button>
      </div>
      {open ? (
        <ScrollArea
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-model-group-viewport"
        >
          <div className="bft-checklist" id={bodyId}>
            {swarms.map((swarm) => {
              const memberInherited = inheritedProjIds.has(swarm.id);
              const checked = memberInherited || explicitProjIds.has(swarm.id);
              const hint = memberHint(swarm, memberInherited, searcherIfcOff);
              return (
                <Checkbox
                  checked={checked}
                  disabled={disabled || memberInherited}
                  {...(hint ? { hint } : {})}
                  key={swarm.id}
                  label={swarm.name}
                  onChange={(event) => onToggleMember(swarm.id, event.target.checked)}
                  size="sm"
                />
              );
            })}
          </div>
        </ScrollArea>
      ) : null}
    </section>
  );
}
