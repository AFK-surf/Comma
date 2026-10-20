import { getNativeBridge } from "@comma/native-bridge";
import { Toaster } from "@comma/ui/components/toast";
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { useState } from "react";
import { CommaAuthGate } from "../../AuthGate";
import { CommaAppearanceProvider } from "../../commaAppearance";
import { PluginNotices } from "../../plugins/pluginInstall";
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
  return (
    <RouterIdentityProvider>
      <PluginNotices />
      <OnboardingWindowFlow />
    </RouterIdentityProvider>
  );
}

/**
 * Main records the completion when the window asks to close. An app still
 * being authorized in the browser goes on in the client core, which no window
 * owns.
 */
function OnboardingWindowFlow() {
  return (
    <OnboardingExperience
      onComplete={recordedByMain}
      onExited={exitWindow}
      presentation="window"
    />
  );
}

// Main records the completion, for the user it presented the window to, when
// the window asks to close.
function recordedByMain() {}

function exitWindow() {
  void getNativeBridge()
    .onboarding.closeWindow({})
    .catch((error: unknown) => {
      console.error("[onboarding] window close handoff failed", error);
    });
}
