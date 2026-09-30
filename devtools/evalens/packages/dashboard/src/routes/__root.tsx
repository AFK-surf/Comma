import { Link, Outlet, createRootRoute } from "@tanstack/react-router";
import { CompareTray } from "../components/CompareTray";
import { CompareSelectionProvider } from "../selection/CompareSelection";
import { LocaleMenu, useLocale, useMessages } from "../i18n/locale";

export const Route = createRootRoute({ component: RootRoute });

function RootRoute() {
  const { locale } = useLocale();
  const m = useMessages();
  return (
    <CompareSelectionProvider>
      <div className="app-frame" data-locale={locale}>
        <nav className="topbar">
          <Link className="brand" search={{ page: 1 }} to="/">
            Evalens
          </Link>
          <div className="topbar-actions">
            <div className="nav-links">
              <Link activeProps={{ className: "active" }} search={{ page: 1 }} to="/">
                {m.nav_runs()}
              </Link>
              <Link
                activeProps={{ className: "active" }}
                search={{ page: 1 }}
                to="/evaluations"
              >
                {m.nav_evaluations()}
              </Link>
              <Link
                activeProps={{ className: "active" }}
                search={{
                  eval: [],
                  itemPage: 1,
                  catalogPage: 1,
                  reference: undefined,
                }}
                to="/compare"
              >
                {m.nav_compare()}
              </Link>
            </div>
            <LocaleMenu />
          </div>
        </nav>
        <Outlet />
        <CompareTray />
      </div>
    </CompareSelectionProvider>
  );
}
