import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

export type CommaSidebarContextValue = {
  /**
   * The Chat Sidebar is open on the trailing edge. Carried here so the content
   * panel can mark itself for CSS: a `:has()` on the aside's open state made
   * every toggle invalidate the whole panel's styles.
   */
  chatSidebarOpen: boolean;
  /** The rail is out of the layout; the content panel takes its width. */
  collapsed: boolean;
  toggleCollapsed: () => void;
};

const CommaSidebarContext = createContext<CommaSidebarContextValue>({
  chatSidebarOpen: false,
  collapsed: false,
  toggleCollapsed: () => {},
});

/**
 * Collapse state for the icon rail. The rail has no drag or peek affordance;
 * it is shown or hidden as a whole. Two things hide it: the reader, from the
 * toggle-left-sidebar shortcut or the rail's edge, and geometry, when the
 * frame cannot hold the rail beside the route (`railFits`, see
 * `railFitsFrame`). The reader's choice outlives a narrow spell; geometry's
 * does not, so the rail returns by itself once the window can hold it.
 */
export function CommaSidebarProvider({
  chatSidebarOpen = false,
  children,
  railFits = true,
}: {
  chatSidebarOpen?: boolean;
  children: ReactNode;
  railFits?: boolean;
}) {
  const [hidden, setHidden] = useState(false);
  const collapsed = hidden || !railFits;
  const collapsedRef = useRef(collapsed);
  collapsedRef.current = collapsed;
  // Aims at the opposite of what shows: hiding a shown rail records the
  // choice; asking for a hidden rail clears it, even while geometry keeps the
  // rail out until the window can hold it.
  const toggleCollapsed = useCallback(() => {
    setHidden(!collapsedRef.current);
  }, []);
  const value = useMemo<CommaSidebarContextValue>(
    () => ({ chatSidebarOpen, collapsed, toggleCollapsed }),
    [chatSidebarOpen, collapsed, toggleCollapsed]
  );

  return (
    <CommaSidebarContext.Provider value={value}>
      {children}
    </CommaSidebarContext.Provider>
  );
}

export function useCommaSidebar() {
  return useContext(CommaSidebarContext);
}
