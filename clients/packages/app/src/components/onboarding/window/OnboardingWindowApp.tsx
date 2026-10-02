import { getNativeBridge } from "@comma/native-bridge";
import { Toaster } from "@comma/ui";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { CommaAuthGate, useCommaAuth } from "../../AuthGate";
import { CommaAppearanceProvider } from "../../commaAppearance";
import {
  PluginInstallProvider,
  usePluginInstall,
} from "../../plugins/PluginInstallProvider";
import { RouterIdentityProvider } from "../../router-identity/RouterIdentityProvider";
import { OnboardingExperience } from "../OnboardingExperience";

/**
 * The renderer of Electron's full-screen onboarding window. The window is a
 * transparent sheet over the desktop and the experience paints its own veil
 * and light. Main presents it for the signed-in user and closes it when that
 * user signs out; this renderer asks Main to close the window once the exit
 * reveal after "Start chatting" is over. Main then records completion and
 * hands the user to the main window's Home.
 *
 * Unlike the other accessory windows this one has a toast stack: plugin
 * authorization reports its failures only as toasts. Main fits the window to
 * the display below its menu bar and keeps it above the Dock while Comma is
 * active, so the whole window is usable and the stack keeps its usual insets.
 */
export function OnboardingWindowApp() {
  const [router] = useState(createOnboardingWindowRouter);

  return (
    <CommaAppearanceProvider syncNativeAppearance={false}>
      <RouterProvider router={router} />
      <Toaster />
    </CommaAppearanceProvider>
  );
}

// Plugin authorization follows the product router (it returns to Home after an
// install). This window has one location.
function createOnboardingWindowRouter() {
  const rootRoute = createRootRoute();
  return createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([
      createRoute({
        component: OnboardingWindowSession,
        getParentRoute: () => rootRoute,
        path: "/",
      }),
    ]),
  });
}

function OnboardingWindowSession() {
  return (
    <CommaAuthGate signedOutFallback={null}>
      <OnboardingWindowExperience />
    </CommaAuthGate>
  );
}

function OnboardingWindowExperience() {
  const { api, sessionSignal } = useCommaAuth();

  return (
    <RouterIdentityProvider>
      <PluginInstallProvider api={api} sessionSignal={sessionSignal}>
        <OnboardingWindowFlow />
      </PluginInstallProvider>
    </RouterIdentityProvider>
  );
}

/**
 * Main records the completion when the window asks to close. An app still
 * being authorized in the browser goes with that request to the main window,
 * which verifies it from then on.
 */
function OnboardingWindowFlow() {
  const { authorization } = usePluginInstall();
  const latestAuthorization = useRef(authorization);
  useEffect(() => {
    latestAuthorization.current = authorization;
  });
  const exited = useCallback(() => {
    const pluginAuthorization = latestAuthorization.current;
    void getNativeBridge()
      .onboarding.closeWindow(pluginAuthorization ? { pluginAuthorization } : {})
      .catch((error: unknown) => {
        console.error("[onboarding] window close handoff failed", error);
      });
  }, []);

  return (
    <OnboardingExperience
      onComplete={recordedByMain}
      onExited={exited}
      presentation="window"
    />
  );
}

// Main records the completion, for the user it presented the window to, when
// the window asks to close.
function recordedByMain() {}
