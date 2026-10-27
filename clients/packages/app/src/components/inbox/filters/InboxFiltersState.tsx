import {
  createContext,
  useContext,
  useMemo,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";
import { unfilteredInbox, type InboxFilters } from "./inboxFilters";

type InboxFiltersState = readonly [
  InboxFilters,
  Dispatch<SetStateAction<InboxFilters>>,
];

const InboxFiltersContext = createContext<InboxFiltersState | undefined>(undefined);

/**
 * The Inbox filters of one authenticated session. The rail unmounts when the
 * reader opens another page and remounts while a list reloads; the filters
 * stay until the reader clears them or the session ends.
 */
export function InboxFiltersProvider({ children }: { children: ReactNode }) {
  const [filters, setFilters] = useState(unfilteredInbox);
  const state = useMemo(() => [filters, setFilters] as const, [filters]);
  return (
    <InboxFiltersContext.Provider value={state}>
      {children}
    </InboxFiltersContext.Provider>
  );
}

/**
 * The session's Inbox filters. Without a provider they fall back to state
 * local to the caller, which lasts only as long as it stays mounted. That
 * keeps mounts without a session, such as the e2e inbox-performance page,
 * working. A page in the app must sit under `InboxFiltersProvider`.
 */
export function useInboxFilters(): InboxFiltersState {
  const local = useState(unfilteredInbox);
  return useContext(InboxFiltersContext) ?? local;
}
