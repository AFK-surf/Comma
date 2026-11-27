import { useContext } from "react";
import { CommaAuthContext } from "../auth-context";
import { useTopic } from "@comma/core-client";
import { useWorkspacePreference } from "../activeWorkspace";
import type { Face } from "./AvatarStack";

/**
 * The name of another person the account works with, by their user id: from People (Task requests' people), else
 * from the Tasks together the account joined (their host and members). Undefined when neither knows them.
 */
export function usePersonName(userId: string | undefined): string | undefined {
  const prefer = useWorkspacePreference();
  const people = useTopic(
    userId && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  ).value?.people;
  const collaborations = useTopic(userId ? { topic: "collaborations" } : null).value
    ?.items;
  if (!userId) return undefined;
  const contact = people?.find((person) => person.id === userId);
  if (contact) return contact.name || contact.email || undefined;
  for (const item of collaborations ?? []) {
    if (item.host?.id === userId) return item.host.name ?? undefined;
    const member = item.members.find((entry) => entry.person?.id === userId);
    if (member?.person?.name) return member.person.name;
  }
  return undefined;
}

/** People the account works with, by user id, as faces (in the order given); one unknown to it is unnamed. */
export function usePeopleFaces(ids: readonly string[]): Face[] {
  const auth = useContext(CommaAuthContext);
  const prefer = useWorkspacePreference();
  const people = useTopic(
    ids.length > 0 && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  ).value?.people;
  return ids.map((id) => {
    // The account itself (a Task it hosts lists its host first).
    if (id === auth?.userId)
      return {
        id,
        name: auth.userDisplayName ?? null,
        email: auth.userEmail,
        avatar: auth.avatarRevision
          ? { source: "avatar", revision: auth.avatarRevision }
          : null,
      };
    const contact = people?.find((person) => person.id === id);
    return {
      id,
      name: contact?.name ?? null,
      email: contact?.email ?? null,
      avatar: contact?.avatar ?? null,
    };
  });
}

/**
 * Where the avatar of someone the account works with is read, by user id: its own for the account, else People's;
 * none for anyone else (a Task's host or member outside People shows their initials).
 */
export function usePeopleAvatars(
  /** False reads nothing (a surface with no one else on it): every face is then its initials. */
  enabled = true
): (id: string | null | undefined) => Face["avatar"] {
  const auth = useContext(CommaAuthContext);
  const prefer = useWorkspacePreference();
  const people = useTopic(
    enabled && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  ).value?.people;
  return (id) => {
    if (!id) return null;
    if (id === auth?.userId)
      return auth.avatarRevision
        ? { source: "avatar", revision: auth.avatarRevision }
        : null;
    return people?.find((person) => person.id === id)?.avatar ?? null;
  };
}
