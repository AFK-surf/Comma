import { Button, Dialog, Dropdown, InputField, ScrollArea } from "@comma/ui";
import { useState } from "react";
import type { BftMember, BftMembers, BftOrgRole } from "./api";
import { ConfirmDialog, DialogError, writeErrorMessage } from "./dialogs";
import { formatRelative } from "./format";
import { messages } from "./messages";
import type { Resource } from "./resource";
import { ErrorState, Skeleton } from "./states";

const t = messages.members;

export interface MemberWrites {
  invite: (invite: { email: string; role: BftOrgRole }) => Promise<BftMembers>;
  changeRole: (userId: string, role: BftOrgRole) => Promise<BftMembers>;
  remove: (userId: string) => Promise<BftMembers>;
}

type Pending =
  | { kind: "invite" }
  | { kind: "role"; member: BftMember; role: BftOrgRole }
  | { kind: "remove"; member: BftMember };

export const memberName = (member: BftMember) =>
  member.name ?? member.email ?? member.mobile ?? t.unnamed;

/** The roles this viewer may hand out; only owners grant the owner role. */
export function grantableRoles(viewer: BftMembers["viewer"]): BftOrgRole[] {
  return viewer.can_grant_owner ? ["owner", "admin", "member"] : ["admin", "member"];
}

/**
 * Whether the viewer may change `member`'s role. Admins leave owners alone, and
 * nobody changes their own role except an owner stepping down while another
 * owner remains (the server still guards the last owner).
 */
export function canEditRole(members: BftMembers, member: BftMember) {
  const { viewer } = members;
  if (!viewer.can_manage) return false;
  if (member.role === "owner" && !viewer.can_grant_owner) return false;
  if (member.user_id !== viewer.user_id) return true;
  const owners = members.members.filter((candidate) => candidate.role === "owner");
  return viewer.role === "owner" && owners.length > 1;
}

/** Removing yourself is not offered here; admins cannot remove owners. */
export function canRemove(members: BftMembers, member: BftMember) {
  const { viewer } = members;
  return (
    viewer.can_manage &&
    member.user_id !== viewer.user_id &&
    (member.role !== "owner" || viewer.can_grant_owner)
  );
}

export function MembersPage({
  orgName,
  members,
  onRetry,
  writes,
}: {
  orgName: string | undefined;
  members: Resource<BftMembers>;
  onRetry: () => void;
  writes: MemberWrites;
}) {
  // Every write answers with the whole list; it replaces the first load.
  const [latest, setLatest] = useState<BftMembers>();
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const data = latest ?? (members.state === "ready" ? members.data : undefined);

  const open = (next: Pending) => {
    setError(undefined);
    setPending(next);
  };
  const close = () => {
    if (busy) return;
    setPending(null);
    setError(undefined);
  };
  const run = (write: () => Promise<BftMembers>) => {
    setBusy(true);
    setError(undefined);
    write().then(
      (next) => {
        setLatest(next);
        setBusy(false);
        setPending(null);
      },
      (caught: unknown) => {
        setBusy(false);
        setError(writeErrorMessage(caught));
      }
    );
  };

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {data?.viewer.can_manage ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => open({ kind: "invite" })}
              type="button"
            >
              {t.invite}
            </button>
          ) : null}
        </div>
      </div>
      {members.state === "error" && !latest ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <MembersTable
          data={data}
          onChangeRole={(member, role) => open({ kind: "role", member, role })}
          onRemove={(member) => open({ kind: "remove", member })}
        />
      )}
      {data && pending?.kind === "invite" ? (
        <InviteDialog
          busy={busy}
          error={error}
          onClose={close}
          onInvite={(invite) => run(() => writes.invite(invite))}
          onInvalid={setError}
          orgName={orgName ?? ""}
          roles={grantableRoles(data.viewer)}
        />
      ) : null}
      {pending?.kind === "role" ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={t.changeRoleConfirm}
          description={t.changeRoleBody(
            memberName(pending.member),
            t.roles[pending.member.role],
            t.roles[pending.role]
          )}
          error={error}
          onClose={close}
          onConfirm={() =>
            run(() => writes.changeRole(pending.member.user_id, pending.role))
          }
          title={t.changeRoleTitle}
        >
          {pending.role === "owner" ? (
            <p className="bft-dialog-note">{t.changeRoleOwnerNote}</p>
          ) : null}
        </ConfirmDialog>
      ) : null}
      {pending?.kind === "remove" ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={t.removeConfirm}
          description={t.removeBody(memberName(pending.member), orgName ?? "")}
          destructive
          error={error}
          onClose={close}
          onConfirm={() => run(() => writes.remove(pending.member.user_id))}
          title={t.removeTitle}
        />
      ) : null}
    </div>
  );
}

function MembersTable({
  data,
  onChangeRole,
  onRemove,
}: {
  data: BftMembers | undefined;
  onChangeRole: (member: BftMember, role: BftOrgRole) => void;
  onRemove: (member: BftMember) => void;
}) {
  const manage = data?.viewer.can_manage ?? false;
  return (
    <section aria-labelledby="bft-members-title" className="bft-panel bft-panel-table">
      <div className="bft-panel-header">
        <h2 id="bft-members-title">{t.listTitle}</h2>
        {data ? <span className="bft-count">{data.members.length}</span> : null}
      </div>
      {!data ? (
        <div className="bft-rows-skeleton">
          {Array.from({ length: 5 }, (_, index) => (
            <Skeleton height={14} key={index} />
          ))}
        </div>
      ) : data.members.length === 0 ? (
        <p className="bft-quiet">{t.empty}</p>
      ) : (
        <ScrollArea
          className="bft-panel-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-scroll-viewport"
        >
          <table className="bft-table bft-members">
            <thead>
              <tr>
                <th scope="col">{t.columnName}</th>
                <th className="bft-col-contact" scope="col">
                  {t.columnContact}
                </th>
                <th className="bft-col-member-role" scope="col">
                  {t.columnRole}
                </th>
                <th className="bft-col-joined" scope="col">
                  {t.columnJoined}
                </th>
                {manage ? (
                  <th className="bft-col-actions" scope="col">
                    <span className="bft-sr-only">{t.columnActions}</span>
                  </th>
                ) : null}
              </tr>
            </thead>
            <tbody>
              {data.members.map((member) => (
                <MemberRow
                  data={data}
                  key={member.user_id}
                  manage={manage}
                  member={member}
                  onChangeRole={onChangeRole}
                  onRemove={onRemove}
                />
              ))}
            </tbody>
          </table>
        </ScrollArea>
      )}
    </section>
  );
}

function MemberRow({
  data,
  member,
  manage,
  onChangeRole,
  onRemove,
}: {
  data: BftMembers;
  member: BftMember;
  manage: boolean;
  onChangeRole: (member: BftMember, role: BftOrgRole) => void;
  onRemove: (member: BftMember) => void;
}) {
  const name = memberName(member);
  const contact = member.email ?? member.mobile;
  const provider = member.sso_provider
    ? (t.providers[member.sso_provider] ?? member.sso_provider)
    : undefined;
  const self = member.user_id === data.viewer.user_id;
  const joined = member.joined_at ? formatRelative(member.joined_at) : undefined;
  const roles = grantableRoles(data.viewer);

  return (
    <tr>
      <td>
        <span className="bft-member-name">
          <span className="bft-truncate" title={name}>
            {name}
          </span>
          {self ? <span className="bft-member-you">{t.you}</span> : null}
        </span>
      </td>
      <td className="bft-col-contact">
        <span className="bft-member-contact">
          <span className="bft-truncate" title={contact ?? undefined}>
            {contact ?? "—"}
          </span>
          {provider ? <span className="bft-tag">{t.sso(provider)}</span> : null}
        </span>
      </td>
      <td className="bft-col-member-role">
        {canEditRole(data, member) ? (
          <Dropdown
            ariaLabel={t.roleFor(name)}
            items={roles.map((role) => ({ id: role, label: t.roles[role] }))}
            onChange={(role) => {
              if (role !== member.role) onChangeRole(member, role as BftOrgRole);
            }}
            size="xs"
            value={member.role}
            width="content"
          />
        ) : (
          <span className="bft-role-text">{t.roles[member.role]}</span>
        )}
      </td>
      <td className="bft-col-joined" title={member.joined_at ?? undefined}>
        {joined ?? "—"}
      </td>
      {manage ? (
        <td className="bft-col-actions">
          {canRemove(data, member) ? (
            <Button
              aria-label={t.removeFor(name)}
              hierarchy="tertiary-gray"
              onPress={() => onRemove(member)}
              size="xs"
            >
              {t.remove}
            </Button>
          ) : null}
        </td>
      ) : null}
    </tr>
  );
}

function InviteDialog({
  orgName,
  roles,
  busy,
  error,
  onInvite,
  onInvalid,
  onClose,
}: {
  orgName: string;
  roles: BftOrgRole[];
  busy: boolean;
  error: string | undefined;
  onInvite: (invite: { email: string; role: BftOrgRole }) => void;
  onInvalid: (message: string) => void;
  onClose: () => void;
}) {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<BftOrgRole>("member");

  const submit = () => {
    const trimmed = email.trim();
    if (!trimmed) {
      onInvalid(t.emailRequired);
      return;
    }
    onInvite({ email: trimmed, role });
  };

  return (
    <Dialog
      actions={[
        {
          label: messages.common.cancel,
          hierarchy: "secondary-gray",
          onPress: onClose,
          disabled: busy,
        },
        {
          label: busy ? messages.common.working : t.inviteConfirm,
          hierarchy: "primary",
          onPress: submit,
          disabled: busy,
        },
      ]}
      description={t.inviteBody(orgName)}
      isDismissable={!busy}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={t.inviteTitle}
    >
      <div className="bft-form">
        <InputField
          autoComplete="off"
          disabled={busy}
          label={t.emailLabel}
          name="email"
          onChange={(event) => setEmail(event.target.value)}
          placeholder={t.emailPlaceholder}
          type="email"
          value={email}
          className="w-full"
          wrapperClassName="bft-form-field"
        />
        <Dropdown
          className="bft-form-field"
          disabled={busy}
          items={roles.map((option) => ({
            id: option,
            label: t.roles[option],
            subtitle: t.roleHints[option],
          }))}
          label={t.roleLabel}
          onChange={(value) => setRole(value as BftOrgRole)}
          size="sm"
          value={role}
        />
        <DialogError message={error} />
      </div>
    </Dialog>
  );
}
