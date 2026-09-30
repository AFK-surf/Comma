import { useEffect } from "react";
import { useRouterState } from "@tanstack/react-router";
import { installCommaNavTrace, snapshotHomeDom, traceCommaNav } from "./commaNavTrace";

export function CommaNavTraceRoot() {
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  });

  useEffect(() => installCommaNavTrace(), []);
  useEffect(() => {
    traceCommaNav("route", { pathname, ...snapshotHomeDom() });
  }, [pathname]);

  return null;
}
