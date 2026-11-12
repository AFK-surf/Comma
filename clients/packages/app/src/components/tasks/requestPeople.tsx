import type { FileSource } from "@comma/core-client";
import type { TaskFilterOption } from "@comma/ui/components/task-workspace";
import { RequestPersonAvatar } from "./RequestPersonAvatar";

/** Which way a request went between the person and someone else: they sent it to the person, or the person to them. */
export type RequestDirection = "from" | "to";

/**
 * A Request filter's option for one person and direction. Their User id keeps two people of one name apart; a Task
 * from before the id was kept falls back to the name.
 */
export const requestPersonKey = (
  direction: RequestDirection,
  person: { id?: string | null | undefined; name?: string | null | undefined }
) => `${direction}:${person.id ? person.id : `name:${person.name ?? ""}`}`;

/** A person seen on a request, as one Request filter option shows them. */
export interface RequestPersonFacts {
  name: string;
  email?: string | null | undefined;
  avatar?: FileSource | undefined;
}

export interface RequestPersonTally extends RequestPersonFacts {
  key: string;
  count: number;
}

/** Counts what each person sent or received; the first sighting names them and gives their avatar. */
export class RequestPeople {
  readonly #byKey = new Map<string, RequestPersonTally>();

  add(key: string, facts: RequestPersonFacts) {
    const known = this.#byKey.get(key);
    if (known) {
      known.count += 1;
      if (!known.avatar && facts.avatar) known.avatar = facts.avatar;
    } else this.#byKey.set(key, { ...facts, key, count: 1 });
  }

  /** By name, so the menu keeps its order as counts change. */
  list(locale: string): RequestPersonTally[] {
    return [...this.#byKey.values()].toSorted(
      (a, b) => a.name.localeCompare(b.name, locale) || a.key.localeCompare(b.key)
    );
  }
}

/** One filter option per person, with their avatar, under the group's heading. */
export function requestPersonOptions(
  people: readonly RequestPersonTally[],
  group: string
): TaskFilterOption[] {
  return people.map((person) => ({
    count: person.count,
    group,
    icon: (
      <RequestPersonAvatar
        className="[&>img]:size-4! [&>span]:size-4! [&>span]:text-[8px]!"
        email={person.email}
        name={person.name}
        source={person.avatar}
      />
    ),
    id: person.key,
    label: person.name,
  }));
}
