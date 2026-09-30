import { useEffect } from "react";
import { BftNotFoundError, BftUnauthenticatedError } from "./api";
import { messages } from "./messages";
import { OverviewPage } from "./OverviewPage";
import { useApi, useResource } from "./resource";
import { matchRoute, navigate, rootRedirect, usePathname } from "./router";
import { Shell } from "./Shell";
import { ErrorState, OrgNotFound, PageNotFound } from "./states";

export function App() {
  const pathname = usePathname();
  const route = matchRoute(pathname);

  switch (route.name) {
    case "root":
      return <RootRedirect />;
    case "org-overview":
      return <OrgOverview org={route.org} pathname={pathname} />;
    default:
      return <PageNotFound />;
  }
}

function RootRedirect() {
  const api = useApi();
  const [session, retry] = useResource("session", (signal) => api.session(signal));

  useEffect(() => {
    if (session.state !== "ready") return;
    const redirect = rootRedirect(session.data);
    if (redirect.kind === "replace") navigate(redirect.path, { replace: true });
    else window.location.assign(redirect.href);
  }, [session]);

  if (
    session.state === "error" &&
    !(session.error instanceof BftUnauthenticatedError)
  ) {
    return (
      <div className="bft-state-page">
        <ErrorState onRetry={retry} />
      </div>
    );
  }
  return (
    <div aria-busy="true" className="bft-state-page">
      <span className="bft-sr-only">{messages.states.redirecting}</span>
    </div>
  );
}

function OrgOverview({ org, pathname }: { org: string; pathname: string }) {
  const api = useApi();
  const [context, retryContext] = useResource(`context:${org}`, (signal) =>
    api.orgContext(org, signal)
  );
  const [overview, retryOverview] = useResource(`overview:${org}`, (signal) =>
    api.overview(org, signal)
  );
  const ready = context.state === "ready" ? context.data : undefined;

  useEffect(() => {
    document.title = ready
      ? `${messages.overview.title} · ${ready.org.name}`
      : messages.productName;
  }, [ready]);

  const notFound = [context, overview].some(
    (resource) =>
      resource.state === "error" && resource.error instanceof BftNotFoundError
  );
  const unauthenticated = [context, overview].some(
    (resource) =>
      resource.state === "error" && resource.error instanceof BftUnauthenticatedError
  );

  if (notFound) {
    return (
      <div className="bft-state-page">
        <OrgNotFound />
      </div>
    );
  }

  return (
    <Shell context={ready} pathname={pathname}>
      {context.state === "error" && !unauthenticated ? (
        <ErrorState onRetry={retryContext} />
      ) : (
        <OverviewPage
          onRetry={retryOverview}
          org={org}
          orgName={ready?.org.name}
          overview={unauthenticated ? { state: "loading" } : overview}
        />
      )}
    </Shell>
  );
}
