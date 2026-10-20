import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useRef, useState, type ChangeEvent } from "react";
import type { BftSkillDraft, BftSwarmSkill, BftSwarmSkills } from "./api";
import { writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useLastReady, useResource, type Resource } from "./resource";
import { spaLinkClick } from "./router";
import {
  FormDialog,
  FormSection,
  SettingsPage,
  TextAreaField,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { Skeleton, StaleNotice } from "./states";

const t = messages.swarmSkills;

/** The `[a-z0-9-]` id a skill name is stored under; "" when nothing usable remains. */
export function skillSlug(name: string) {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return /^[a-z0-9][a-z0-9-]*$/.test(slug) ? slug : "";
}

/** A `SKILL.md` body without its frontmatter. */
export function skillBody(content: string) {
  const text = content.replace(/\r\n/g, "\n");
  const parts = text.split("---");
  return (
    parts.length >= 3 && parts[0] === "" ? parts.slice(2).join("---") : text
  ).trim();
}

/** Why a file cannot be uploaded, before it is read; undefined when it can. */
export function uploadProblem(
  file: { name: string; size: number },
  limits: BftSwarmSkills["limits"]
) {
  const dot = file.name.lastIndexOf(".");
  const extension = dot >= 0 ? file.name.slice(dot).toLowerCase() : "";
  if (!limits.extensions.includes(extension)) return t.uploadType;
  if (file.size > limits.max_bytes) return t.uploadTooLarge;
  return undefined;
}

/**
 * An Agent Swarm's skills, managed through its Router: the custom skills
 * (created here, uploaded or saved from chat) and the read-only system skills
 * the runtime and plugins project into it. Admins create, upload and delete
 * custom skills; everyone can read a skill.
 */
export function SwarmSkillsPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmSkills>;
  onRetry: () => void;
}) {
  const api = useApi();
  const { data, resource, stale } = useLastReady(first);
  const [creating, setCreating] = useState(false);
  const [viewing, setViewing] = useState<BftSwarmSkill | null>(null);
  const [uploading, setUploading] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const confirm = useConfirm();
  const path = projectHref(org, project, "/skills");
  const manage = data?.project.role === "admin" && data.agent !== null;

  const notify = (notice: string) => {
    showFlash({ kind: "info", text: notice }, path);
    onRetry();
  };
  const refuse = (text: string | undefined) => {
    if (text) showFlash({ kind: "error", text }, path);
    onRetry();
  };

  const upload = (event: ChangeEvent<HTMLInputElement>) => {
    const input = event.target;
    const file = input.files?.[0];
    input.value = "";
    if (!file || !data) return;
    const problem = uploadProblem(file, data.limits);
    if (problem) {
      refuse(problem);
      return;
    }
    setUploading(true);
    file
      .text()
      .then((content) =>
        api.uploadSkill(org, project, { filename: file.name, content })
      )
      .then(
        ({ notice }) => {
          setUploading(false);
          notify(notice);
        },
        (error: unknown) => {
          setUploading(false);
          refuse(writeErrorMessage(error));
        }
      );
  };

  const remove = (skill: BftSwarmSkill) =>
    confirm.ask({
      title: t.deleteTitle,
      description: t.deleteBody(skill.name),
      confirmLabel: t.delete,
      action: () =>
        api.deleteSkill(org, project, skill.id).then(({ notice }) => notify(notice)),
    });

  return (
    <>
      <SettingsPage
        actions={
          manage && data ? (
            <>
              <input
                accept={data.limits.extensions.join(",")}
                aria-label={t.uploadLabel}
                className="bft-sr-only"
                onChange={upload}
                ref={fileRef}
                tabIndex={-1}
                type="file"
              />
              <button
                className="bft-btn"
                disabled={uploading}
                onClick={() => fileRef.current?.click()}
                type="button"
              >
                {uploading ? t.uploading : t.upload}
              </button>
              <button
                className="bft-btn bft-btn-primary"
                onClick={() => setCreating(true)}
                type="button"
              >
                {t.create}
              </button>
            </>
          ) : undefined
        }
        description={data ? t.description(data.project.name) : undefined}
        onRetry={onRetry}
        resource={resource}
        title={t.title}
        wide
      >
        {(page) => (
          <>
            {stale ? <StaleNotice onRetry={onRetry} /> : null}
            <Skills
              manage={page.project.role === "admin"}
              onDelete={remove}
              onRetry={onRetry}
              onView={setViewing}
              page={page}
            />
          </>
        )}
      </SettingsPage>
      {creating ? (
        <NewSkillDialog
          onClose={() => setCreating(false)}
          onCreated={(notice) => {
            setCreating(false);
            notify(notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
      {viewing ? (
        <SkillDialog
          canDelete={data?.project.role === "admin" && viewing.deletable}
          onClose={() => setViewing(null)}
          onDelete={() => {
            setViewing(null);
            remove(viewing);
          }}
          org={org}
          project={project}
          skill={viewing}
        />
      ) : null}
      {confirm.dialog}
    </>
  );
}

function Skills({
  page,
  manage,
  onView,
  onDelete,
  onRetry,
}: {
  page: BftSwarmSkills;
  manage: boolean;
  onView: (skill: BftSwarmSkill) => void;
  onDelete: (skill: BftSwarmSkill) => void;
  onRetry: () => void;
}) {
  const unavailable = page.status === "unavailable";
  return (
    <>
      {unavailable ? (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">{t.unavailable}</p>
          <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : null}
      {page.miniskill_status === "catalog_over_budget" ? (
        <output className="bft-notice">
          <p>{t.overBudget}</p>
        </output>
      ) : null}
      {page.agent === null ? (
        unavailable ? null : (
          <FormSection description={t.noAgentBody} title={t.noAgentTitle}>
            {manage ? (
              <a className="bft-link" href={page.agents_href} onClick={spaLinkClick}>
                {t.goToAgents}
              </a>
            ) : null}
          </FormSection>
        )
      ) : (
        <>
          <FormSection
            description={t.customNote(page.agent.name)}
            title={t.customTitle}
          >
            {page.custom.length === 0 ? (
              <p className="bft-quiet bft-quiet-inline">{t.customEmpty}</p>
            ) : (
              <SkillList
                label={t.customTitle}
                manage={manage}
                onDelete={onDelete}
                onView={onView}
                skills={page.custom}
              />
            )}
          </FormSection>
          {page.system.length > 0 || !unavailable ? (
            <FormSection description={t.systemNote} title={t.systemTitle}>
              {page.system.length === 0 ? (
                <p className="bft-quiet bft-quiet-inline">{t.systemEmpty}</p>
              ) : (
                <SkillList
                  label={t.systemTitle}
                  manage={false}
                  onDelete={onDelete}
                  onView={onView}
                  skills={page.system}
                />
              )}
            </FormSection>
          ) : null}
        </>
      )}
    </>
  );
}

function SkillList({
  label,
  skills,
  manage,
  onView,
  onDelete,
}: {
  label: string;
  skills: readonly BftSwarmSkill[];
  manage: boolean;
  onView: (skill: BftSwarmSkill) => void;
  onDelete: (skill: BftSwarmSkill) => void;
}) {
  return (
    <ul aria-label={label} className="bft-list">
      {skills.map((skill) => (
        <li className="bft-skill" key={skill.location}>
          <button
            aria-label={t.view(skill.name)}
            className="bft-skill-main"
            onClick={() => onView(skill)}
            type="button"
          >
            <span className="bft-row-title">
              <span className="bft-plugin-name bft-truncate">{skill.name}</span>
              {skill.activation === "per-message" ? (
                <span className="bft-tag">{t.miniskill}</span>
              ) : null}
              {skill.source === "imported" ? (
                <span className="bft-tag">{t.imported}</span>
              ) : null}
            </span>
            {skill.description ? (
              <span className="bft-plugin-description">{skill.description}</span>
            ) : null}
          </button>
          {manage ? (
            skill.deletable ? (
              <button
                aria-label={t.deleteLabel(skill.name)}
                className="bft-btn bft-btn-sm"
                onClick={() => onDelete(skill)}
                type="button"
              >
                {t.delete}
              </button>
            ) : (
              <span className="bft-muted bft-skill-reason">
                {t.deleteReasons[skill.delete_reason ?? ""] ?? t.deleteReasons.other}
              </span>
            )
          ) : null}
        </li>
      ))}
    </ul>
  );
}

/** A skill's `SKILL.md`, read when the dialog opens: the list carries no content. */
function SkillDialog({
  org,
  project,
  skill,
  canDelete,
  onDelete,
  onClose,
}: {
  org: string;
  project: string;
  skill: BftSwarmSkill;
  canDelete: boolean;
  onDelete: () => void;
  onClose: () => void;
}) {
  const api = useApi();
  const [detail, retry] = useResource(`skill:${org}:${project}:${skill.id}`, (signal) =>
    api.swarmSkill(org, project, skill.id, signal)
  );
  return (
    <Dialog
      actions={[
        ...(canDelete
          ? [{ label: t.delete, hierarchy: "destructive" as const, onPress: onDelete }]
          : []),
        { label: t.close, hierarchy: "secondary-gray", onPress: onClose },
      ]}
      className="bft-dialog-wide"
      description={
        skill.description ?? t.sources[skill.source ?? ""] ?? t.sources.custom
      }
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={skill.name}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <div className="bft-form">
          <p className="bft-dialog-note bft-skill-meta">
            <span>{t.sources[skill.source ?? ""] ?? t.sources.custom}</span>
            <span className="bft-mono">{skill.location}</span>
          </p>
          {detail.state === "ready" ? (
            <pre className="bft-report bft-skill-body">
              {skillBody(detail.data.skill.content)}
            </pre>
          ) : detail.state === "error" ? (
            <div className="bft-quiet-row bft-quiet-row-flush" role="alert">
              <p className="bft-quiet bft-quiet-inline">{t.contentFailed}</p>
              <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
                {messages.states.retry}
              </button>
            </div>
          ) : (
            <output className="bft-rows-skeleton">
              <span className="bft-sr-only">{messages.states.loading}</span>
              <Skeleton height={14} width="40%" />
              <Skeleton height={14} />
              <Skeleton height={14} width="70%" />
            </output>
          )}
        </div>
      </ScrollArea>
    </Dialog>
  );
}

const activations = ["regular", "per-message"] as const;

function NewSkillDialog({
  org,
  project,
  onCreated,
  onClose,
}: {
  org: string;
  project: string;
  onCreated: (notice: string) => void;
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [draft, setDraft] = useState<BftSkillDraft>({
    name: "",
    description: "",
    instructions: "",
    activation: "regular",
  });
  const slug = skillSlug(draft.name);
  const set = (field: keyof BftSkillDraft) => (value: string) =>
    setDraft((previous) => ({ ...previous, [field]: value }));

  return (
    <FormDialog
      description={t.createNote}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () => api.createSkill(org, project, draft),
          ({ notice }) => onCreated(notice)
        )
      }
      submitLabel={t.createSubmit}
      title={t.createTitle}
      wide
      write={write}
    >
      <TextField
        disabled={write.busy}
        error={write.fields.name}
        hint={slug ? t.storedAs(`/.runtime/skills/${slug}/SKILL.md`) : t.storedHint}
        label={t.nameLabel}
        onChange={set("name")}
        value={draft.name}
      />
      <TextField
        disabled={write.busy}
        label={t.descriptionLabel}
        onChange={set("description")}
        value={draft.description}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={activations.map((id) => ({ id, label: t.activations[id] }))}
        label={t.activationLabel}
        onChange={(value) =>
          setDraft((previous) => ({
            ...previous,
            activation: value === "per-message" ? "per-message" : "regular",
          }))
        }
        size="sm"
        value={draft.activation}
      />
      <TextAreaField
        disabled={write.busy}
        label={t.instructionsLabel}
        onChange={set("instructions")}
        rows={6}
        value={draft.instructions}
      />
    </FormDialog>
  );
}
