import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { useCommaI18n, useCommaMessages } from "@comma/i18n/react";
import {
  sessionExpectation,
  sessionPrincipalKind,
  sessionProductLease,
} from "@comma/session-contract";
import { Button } from "@comma/ui/components/Button";
import { Text } from "@comma/ui/components/Text";
import { toast } from "@comma/ui/components/toast";
import {
  useSessionHostController,
  useSessionLifecycleSnapshot,
} from "../session/react";
import { useCall, useTopic } from "@comma/core-client";
import { supportedLocales } from "@comma/i18n";
import { CommaAuthContext, type CommaAuthContextValue } from "./auth-context";
import { LoginScreen } from "./LoginScreen";
import type { SessionHostController } from "../session/controller";
import {
  captureOauthResumeHandle,
  consumeOauthResumeHandle,
  oauthResumeUrl,
  peekOauthResumeHandle,
} from "./oauth-resume";

export function CommaAuthGate({
  children,
  signedOutFallback,
  localManagementEntry,
}: {
  children: ReactNode;
  signedOutFallback?: ReactNode;
  localManagementEntry?: ReactNode;
}) {
  const messages = useCommaMessages();
  const controller = useSessionHostController();
  const snapshot = useSessionLifecycleSnapshot(controller.lifecycle);
  const isGuest =
    snapshot.phase === "signed_in" &&
    sessionPrincipalKind(snapshot.principal) === "guest";
  // The notice follows the handoff through the sign-in steps that come after it.
  const [guestHandoffPending, setGuestHandoffPending] = useState(false);
  if (
    snapshot.phase === "signed_out" &&
    snapshot.reason === "guest_handoff" &&
    !guestHandoffPending
  ) {
    setGuestHandoffPending(true);
  } else if (snapshot.phase === "signed_in" && guestHandoffPending) {
    setGuestHandoffPending(false);
  }

  useEffect(() => {
    void controller.initialize();
  }, [controller]);

  const guest = controller.guest;
  useEffect(
    () =>
      guest?.subscribeImported(() => {
        toast.success(messages.auth_guest_chat_imported());
      }),
    [guest, messages]
  );

  // OAuth IdP round trip (RFC §5, PR 7): the API's authorize endpoint
  // lands logged-out users on /login?oauth_handle={uuid}. Capture runs
  // inside the lazy state initializer so it is complete before this
  // component ever renders — the first committed frame already knows a
  // round trip is pending. The initializer is idempotent (the second
  // StrictMode pass finds a clean URL and the stored handle). On
  // Electron and ordinary visits all of this is a no-op.
  const [oauthResumePending, setOauthResumePending] = useState(() => {
    const cleanedUrl = captureOauthResumeHandle(
      window.location.href,
      window.sessionStorage
    );
    if (cleanedUrl !== undefined) {
      window.history.replaceState(window.history.state, "", cleanedUrl);
    }
    return peekOauthResumeHandle(window.sessionStorage) !== undefined;
  });

  // Once a session exists, send the browser back to the authorize
  // endpoint (top-level navigation, so the Lax session cookie rides
  // along). The handle is single-use on both sides. While the pending
  // flag is up and the session is signed in, the render below shows
  // only the interstitial — the product tree must not mount and no
  // product/profile request may fire before the navigation starts
  // (a mounted product tree would POST /v1/comma/me/bootstrap, which
  // provisions a default Workspace the RP-only user never asked for).
  const oauthResumeStartedRef = useRef(false);

  useEffect(() => {
    if (snapshot.phase !== "signed_in" || !oauthResumePending) {
      return;
    }
    if (oauthResumeStartedRef.current) {
      return;
    }
    oauthResumeStartedRef.current = true;

    const handle = consumeOauthResumeHandle(window.sessionStorage);
    if (handle) {
      // oauthResumePending stays true on purpose: the interstitial must
      // keep covering the product tree while the browser navigates.
      window.location.assign(oauthResumeUrl(controller.apiBaseUrl, handle));
    } else {
      setOauthResumePending(false);
    }
  }, [controller.apiBaseUrl, oauthResumePending, snapshot.phase]);

  const oauthHandoffActive = oauthResumePending && snapshot.phase === "signed_in";

  const signOut = useCallback(() => {
    const current = controller.lifecycle.getSnapshotSync();
    if (current.phase !== "signed_in" && current.phase !== "signed_out") {
      return;
    }
    void controller.lifecycle.signOut({
      expected: sessionExpectation(current),
    });
  }, [controller]);

  const sessionTransport = controller.getProductTransport();
  // The account's profile as the core keeps it (every surface that saves it shows the new one).
  const call = useCall();
  const { value: profileShown } = useTopic(
    snapshot.phase === "signed_in" && sessionTransport && !oauthHandoffActive
      ? { topic: "profile" }
      : null
  );
  const profile = profileShown?.profile ?? undefined;

  // The app language is an account setting. A signed-in device follows the
  // account; an account without one takes this device's current language once.
  const { locale, localePreference, setLocalePreference } = useCommaI18n();
  const accountLocale = supportedLocales.find((l) => l === profile?.locale);
  const profileLoaded = profile !== undefined;
  // Offered once per account.
  const localeOffered = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!profileLoaded) return;
    if (accountLocale) {
      if (accountLocale !== localePreference) setLocalePreference(accountLocale);
      return;
    }
    if (localeOffered.current === profile?.id) return;
    localeOffered.current = profile?.id;
    void call("profile.update", { locale }).catch(() => undefined);
  }, [
    accountLocale,
    call,
    locale,
    localePreference,
    profile?.id,
    profileLoaded,
    setLocalePreference,
  ]);

  // Another tab can move the shared Web Cookie to a different account. The
  // product tree remounts under the new account (see the Provider key below);
  // tell the user why their view changed.
  const signedInUserId =
    snapshot.phase === "signed_in" ? snapshot.principal.userId : undefined;
  // A guest's placeholder email is never shown.
  const signedInEmail =
    snapshot.phase === "signed_in" && !isGuest ? snapshot.principal.email : undefined;
  const previousUserIdRef = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (signedInUserId === undefined) {
      if (snapshot.phase === "signed_out") {
        previousUserIdRef.current = undefined;
      }
      return;
    }
    const previous = previousUserIdRef.current;
    previousUserIdRef.current = signedInUserId;
    if (previous !== undefined && previous !== signedInUserId && signedInEmail) {
      toast.info(messages.auth_account_switched({ email: signedInEmail }));
    }
  }, [messages, signedInEmail, signedInUserId, snapshot.phase]);

  const contextValue = useMemo<CommaAuthContextValue | undefined>(() => {
    if (snapshot.phase !== "signed_in" || !sessionTransport) {
      return undefined;
    }
    const productLease = sessionProductLease(snapshot);
    if (!productLease) {
      return undefined;
    }
    const userDisplayName = isGuest
      ? messages.auth_guest_name()
      : profile?.name || snapshot.principal.displayName;
    const beginGuestSignUp = isGuest ? guest?.beginSignUp : undefined;
    return {
      apiBaseUrl: controller.apiBaseUrl,
      ...(profile?.avatar_id && !isGuest ? { avatarRevision: profile.avatar_id } : {}),
      authenticated: true,
      ...(beginGuestSignUp ? { beginGuestSignUp } : {}),
      isGuest,
      productLease,
      sessionSignal: sessionTransport.signal,
      sessionTransport,
      signOut,
      userId: snapshot.principal.userId,
      ...(userDisplayName ? { userDisplayName } : {}),
      userEmail: snapshot.principal.email,
    };
  }, [
    controller.apiBaseUrl,
    guest,
    isGuest,
    messages,
    profile,
    sessionTransport,
    signOut,
    snapshot,
  ]);

  if (snapshot.phase === "initializing") {
    return null;
  }

  // Synchronous gate: on the first signed-in render with a pending
  // handle, nothing below this line (product tree, signed-in context)
  // may mount. The effect above starts the navigation.
  if (oauthHandoffActive) {
    return (
      <main aria-busy="true" className="app-login-shell">
        <output className="app-login-title">{messages.auth_oauth_returning()}</output>
      </main>
    );
  }

  if (snapshot.phase === "signing_out") {
    return (
      <main aria-busy="true" className="app-login-shell">
        <output className="app-login-title">{messages.auth_signing_out()}</output>
      </main>
    );
  }

  if (snapshot.phase === "invalidating") {
    return (
      <main aria-busy="true" className="app-login-shell">
        <output className="app-login-title">{messages.auth_checking_session()}</output>
      </main>
    );
  }

  if (snapshot.phase === "indeterminate") {
    // A failed sign-out must not recover silently: a successful probe would
    // sign the user back in behind their back.
    if (snapshot.problem.retryable && snapshot.problem.operation !== "sign_out") {
      return <ConnectionRecovery controller={controller} />;
    }
    return (
      <SessionRecoveryScreen
        message={sessionProblemMessage(snapshot.problem.code, messages)}
        onRetry={() => void controller.recover()}
      />
    );
  }

  if (snapshot.phase === "signed_in" && !contextValue) {
    return <ConnectionRecovery controller={controller} />;
  }

  if (contextValue) {
    return (
      <CommaAuthContext.Provider key={contextValue.userId} value={contextValue}>
        {children}
      </CommaAuthContext.Provider>
    );
  }

  if (signedOutFallback !== undefined) {
    return signedOutFallback;
  }

  return (
    <>
      <LoginScreen
        authenticator={controller.authenticator}
        {...(guest && !oauthResumePending ? { guest } : {})}
        {...(guestHandoffPending
          ? { guestHandoffNotice: messages.auth_guest_handoff_notice() }
          : {})}
        revocationPending={snapshot.cleanup.revocation === "pending"}
        {...(oauthResumePending
          ? { oauthResumeNotice: messages.auth_oauth_continue_notice() }
          : {})}
      />
      {localManagementEntry}
    </>
  );
}

// The client core runs one recovery burst for every window (its clock, its delays): the window shows a spinner until
// the core says the burst is spent. A retry or the network coming back asks the core to start a new one.
function ConnectionRecovery({ controller }: { controller: SessionHostController }) {
  const messages = useCommaMessages();
  const exhausted =
    useSyncExternalStore(
      controller.connectionRecovery.subscribe,
      controller.connectionRecovery.get
    ) === "exhausted";

  useEffect(() => {
    if (!exhausted) return;
    const resume = () => void controller.recover().catch(() => undefined);
    window.addEventListener("online", resume);
    return () => window.removeEventListener("online", resume);
  }, [controller, exhausted]);

  if (!exhausted) {
    return (
      <main aria-busy="true" className="app-login-shell">
        <div className="app-login-container">
          <section
            className="app-login-panel"
            aria-label={messages.auth_session_status()}
          >
            <output className="app-login-title" aria-live="polite">
              <LoadingIndicator label={messages.auth_connecting()} />
            </output>
          </section>
        </div>
      </main>
    );
  }

  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        <section
          className="app-login-panel"
          aria-label={messages.auth_session_status()}
        >
          <Text as="h1" weight="semibold" className="app-login-title">
            {messages.auth_connection_unavailable()}
          </Text>
          <div className="app-login-form">
            <p className="app-login-message">{messages.auth_connection_help()}</p>
            <Button
              className="app-login-primary"
              onPress={() => void controller.recover().catch(() => undefined)}
            >
              {messages.auth_try_again()}
            </Button>
          </div>
        </section>
      </div>
    </main>
  );
}

function SessionRecoveryScreen({
  message,
  onRetry,
}: {
  message: string;
  onRetry: () => void;
}) {
  const messages = useCommaMessages();

  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        <section
          className="app-login-panel"
          aria-label={messages.auth_session_status()}
        >
          <Text as="h1" weight="semibold" className="app-login-title">
            {messages.auth_session_unconfirmed_title()}
          </Text>
          <div className="app-login-form">
            <output aria-live="assertive" className="app-login-message" role="alert">
              {message}
            </output>
            <div className="app-login-actions">
              <Button className="app-login-primary" onPress={onRetry}>
                {messages.auth_try_again()}
              </Button>
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}

function sessionProblemMessage(
  code: string,
  messages: ReturnType<typeof useCommaMessages>
) {
  switch (code) {
    case "session_probe_unavailable":
      return messages.auth_network_unavailable();
    case "credential_store_unavailable":
    case "credential_store_unreadable":
      return messages.auth_session_credential_store_unavailable();
    case "credential_mutation_uncertain":
      return messages.auth_session_credential_mutation_uncertain();
    default:
      return messages.auth_session_contract_mismatch();
  }
}

export { useCommaAuth, type CommaAuthContextValue } from "./auth-context";
