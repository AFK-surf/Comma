// The Admin dashboard around the views: which section is open (kept in the URL and the browser history), the
// navigation, and whether the server denied the operator Admin access. The open view's model lives in a Scope of its
// own: leaving the view closes it, which stops its requests. A new lease of the same account opens the view again (its
// reads are made for the new session); another account, a sign-out or a refused session starts the dashboard afresh.
import {
  Context,
  Effect,
  Exit,
  FiberHandle,
  Layer,
  Scope,
  Stream,
  SubscriptionRef,
} from "effect";
import { AdminApi, type AdminRedeemTarget } from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import { AdminShellLinks } from "./adminModel";
import {
  adminSectionFromSearch,
  adminSectionHref,
  type AdminSection,
} from "./adminNavigation";
import { AdminAuth } from "./auth";
import type { SessionLease } from "./adminSession";
import { makeAuditLogModel, type AuditLogModel } from "./AuditLogModel";
import { makeBillingModel, type BillingModel } from "./BillingModel";
import { makeComputeNodesModel, type ComputeNodesModel } from "./ComputeNodesModel";
import {
  makeFreeRouterModelsModel,
  type FreeRouterModelsModel,
} from "./FreeRouterModelsModel";
import { makeGuestModeModel, type GuestModeModel } from "./GuestModeModel";
import { makeOverviewModel, type OverviewModel } from "./OverviewModel";
import { makeSearchModel, type SearchModel } from "./adminSearch";
import { makeOAuthClientsModel, type OAuthClientsModel } from "./OAuthClientsModel";
import { makeUsersModel, type UsersModel } from "./UsersModel";

export type SectionView =
  | { readonly model: AuditLogModel; readonly section: "audit" }
  | { readonly model: BillingModel; readonly section: "billing" }
  | { readonly model: ComputeNodesModel; readonly section: "compute" }
  | { readonly model: FreeRouterModelsModel; readonly section: "free-models" }
  | { readonly model: GuestModeModel; readonly section: "guest" }
  | { readonly model: OAuthClientsModel; readonly section: "oauth" }
  | { readonly model: OverviewModel; readonly section: "overview" }
  | { readonly model: UsersModel; readonly section: "users" };

export interface ShellState {
  readonly accessDenied: boolean;
  readonly section: AdminSection;
  readonly sidebarCollapsed: boolean;
  readonly sidebarOpen: boolean;
  /** The open view, once a session is signed in. */
  readonly view: SectionView | undefined;
}

export class AdminShell extends Context.Service<
  AdminShell,
  {
    readonly state: SubscriptionRef.SubscriptionRef<ShellState>;
    /** The ⌘K search, the same through every view. */
    readonly search: SearchModel;
    readonly select: (section: AdminSection) => Effect.Effect<void>;
    /** Opens the account's page in Users. */
    readonly openUser: (userId: string) => Effect.Effect<void>;
    readonly toggleSidebar: Effect.Effect<void>;
    readonly closeSidebar: Effect.Effect<void>;
  }
>()("admin/AdminShell") {}

const makeView = (
  section: AdminSection,
  redeemTarget: AdminRedeemTarget | undefined
): Effect.Effect<
  SectionView,
  never,
  AdminApi | AdminBrowser | AdminShellLinks | Scope.Scope
> => {
  switch (section) {
    case "audit":
      return Effect.map(makeAuditLogModel(), (model) => ({ model, section }));
    case "billing":
      return Effect.map(makeBillingModel(redeemTarget), (model) => ({
        model,
        section,
      }));
    case "compute":
      return Effect.map(makeComputeNodesModel, (model) => ({ model, section }));
    case "free-models":
      return Effect.map(makeFreeRouterModelsModel, (model) => ({ model, section }));
    case "guest":
      return Effect.map(makeGuestModeModel, (model) => ({ model, section }));
    case "oauth":
      return Effect.map(makeOAuthClientsModel, (model) => ({ model, section }));
    case "overview":
      return Effect.map(makeOverviewModel, (model) => ({ model, section }));
    case "users":
      return Effect.map(makeUsersModel, (model) => ({ model, section }));
  }
};

export const AdminShellLive = Layer.effect(
  AdminShell,
  Effect.gen(function* () {
    const auth = yield* AdminAuth;
    const browser = yield* AdminBrowser;
    const api = yield* AdminApi;
    const sectionNow = browser.href.pipe(
      Effect.map((href) => adminSectionFromSearch(new URL(href).search))
    );
    const state = yield* SubscriptionRef.make<ShellState>({
      accessDenied: false,
      section: yield* sectionNow,
      sidebarCollapsed: false,
      sidebarOpen: false,
      view: undefined,
    });
    const viewFiber = yield* FiberHandle.make();
    let viewScope: Scope.Closeable | undefined;
    let redeemTarget: AdminRedeemTarget | undefined;
    let lease: SessionLease | undefined;

    const closeView = Effect.gen(function* () {
      const scope = viewScope;
      viewScope = undefined;
      yield* SubscriptionRef.update(state, (current) => ({
        ...current,
        view: undefined,
      }));
      if (scope) yield* Scope.close(scope, Exit.void);
    });

    const openView = (section: AdminSection) =>
      Effect.gen(function* () {
        yield* closeView;
        const scope = yield* Scope.make();
        viewScope = scope;
        const target = redeemTarget;
        redeemTarget = undefined;
        const view = yield* makeView(section, target).pipe(
          Scope.provide(scope),
          Effect.provideService(AdminShellLinks, links),
          Effect.provideService(AdminApi, api),
          Effect.provideService(AdminBrowser, browser)
        );
        yield* SubscriptionRef.update(state, (current) =>
          current.section === section && !current.accessDenied
            ? { ...current, view }
            : current
        );
      });

    /** Switches the view in the shell's own fiber, so a view's command may leave its view. */
    const showView = (section: AdminSection) =>
      FiberHandle.run(viewFiber, openView(section)).pipe(Effect.asVoid);

    /** Opens `section` at its start: selecting the open section again leaves a page inside it (a user, a node). */
    const select = (section: AdminSection) =>
      Effect.gen(function* () {
        const href = yield* browser.href;
        const url = new URL(href);
        const target = adminSectionHref(section, href);
        const moved = target !== `${url.pathname}${url.search}${url.hash}`;
        if (moved) yield* browser.push(target);
        const previous = yield* SubscriptionRef.getAndUpdate(state, (current) => ({
          ...current,
          section,
          sidebarOpen: false,
        }));
        if (lease && (moved || previous.section !== section || !previous.view)) {
          yield* showView(section);
        }
      });

    const openUser = (userId: string) =>
      Effect.gen(function* () {
        const href = yield* browser.href;
        const url = new URL(href);
        const target = `${url.pathname}?${new URLSearchParams({ user: userId }).toString()}`;
        if (target !== `${url.pathname}${url.search}`) yield* browser.push(target);
        yield* SubscriptionRef.update(
          state,
          (current): ShellState => ({
            ...current,
            section: "users",
            sidebarOpen: false,
          })
        );
        if (lease) yield* showView("users");
      });

    const links = AdminShellLinks.of({
      openUser,
      applyRedeemCode: (target) =>
        Effect.gen(function* () {
          redeemTarget = target;
          yield* select("billing");
        }),
      denyAccess: Effect.gen(function* () {
        yield* SubscriptionRef.update(state, (current) => ({
          ...current,
          accessDenied: true,
        }));
        yield* FiberHandle.run(viewFiber, closeView);
      }),
      select,
    });

    yield* SubscriptionRef.changes(auth.state).pipe(
      Stream.runForEach((current) =>
        Effect.gen(function* () {
          const next = current.phase === "signed_in" ? current.lease : undefined;
          if (next === lease) return;
          const sameAccount = lease !== undefined && next?.userId === lease.userId;
          lease = next;
          if (!next) {
            yield* FiberHandle.run(viewFiber, closeView);
            return;
          }
          if (!sameAccount) {
            redeemTarget = undefined;
            const section = yield* sectionNow;
            yield* SubscriptionRef.set(state, {
              accessDenied: false,
              section,
              sidebarCollapsed: false,
              sidebarOpen: false,
              view: undefined,
            });
          }
          const { accessDenied, section } = yield* SubscriptionRef.get(state);
          if (!accessDenied) yield* showView(section);
        })
      ),
      Effect.forkScoped
    );

    yield* browser.popstate.pipe(
      Stream.runForEach(() =>
        Effect.gen(function* () {
          const section = yield* sectionNow;
          yield* SubscriptionRef.update(state, (current) => ({
            ...current,
            section,
            sidebarOpen: false,
          }));
          if (lease) yield* showView(section);
        })
      ),
      Effect.forkScoped
    );

    const search = yield* makeSearchModel;

    return AdminShell.of({
      state,
      search,
      select,
      openUser,
      toggleSidebar: Effect.gen(function* () {
        const narrow = yield* browser.narrow;
        yield* SubscriptionRef.update(state, (current) =>
          narrow
            ? { ...current, sidebarOpen: !current.sidebarOpen }
            : { ...current, sidebarCollapsed: !current.sidebarCollapsed }
        );
      }),
      closeSidebar: SubscriptionRef.update(state, (current) => ({
        ...current,
        sidebarOpen: false,
      })),
    });
  })
);
