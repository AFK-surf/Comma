import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import { sessionExpectation } from "@comma/session-contract";
import type { CommaApiSessionTransport } from "../../api";
import type { SessionGuestController, SessionHostController } from "../controller";
import { sessionOperationDisplayError } from "../operation-error-message";
import type { WebSessionHostPorts } from "./coordination-ports";
import {
  WebCookieSessionAdapter,
  type WebCookieSessionProductLease,
} from "./web-cookie-session-adapter";
import { WebCookieLoginController } from "./web-login-controller";

export function createWebSessionHostController(input: {
  apiBaseUrl: string;
  locale?: CommaLocale;
  ports: WebSessionHostPorts;
}): SessionHostController & {
  exchangeTelegramLaunch: WebCookieSessionAdapter["exchangeTelegramLaunch"];
} {
  const lifecycle = new WebCookieSessionAdapter({
    baseUrl: input.apiBaseUrl,
    ports: input.ports,
  });
  return createWebSessionHostControllerFromAdapter(lifecycle, input.locale);
}

/** Attach the UI to the same Cookie authority that handled early authentication. */
export function createWebSessionHostControllerFromAdapter(
  lifecycle: WebCookieSessionAdapter,
  locale?: CommaLocale
): SessionHostController & {
  exchangeTelegramLaunch: WebCookieSessionAdapter["exchangeTelegramLaunch"];
} {
  const authenticator = new WebCookieLoginController(lifecycle, locale);
  let initialization: Promise<void> | undefined;
  let cachedProduct:
    | {
        lease: WebCookieSessionProductLease;
        transport: CommaApiSessionTransport;
      }
    | undefined;

  const guestLocale = locale ?? baseLocale;
  const guestError = (code: string) =>
    sessionOperationDisplayError(
      code,
      messages.auth_guest_unavailable({}, { locale: guestLocale }),
      guestLocale
    );
  const guest: SessionGuestController = {
    availability: () => lifecycle.guestAvailability(),
    async beginSignUp() {
      const snapshot = lifecycle.getSnapshotSync();
      if (snapshot.phase !== "signed_in") {
        throw new Error(messages.auth_attempt_stale({}, { locale: guestLocale }));
      }
      const result = await lifecycle.beginGuestSignUp({
        expected: sessionExpectation(snapshot),
      });
      if (!result.ok) throw guestError(result.error.code);
    },
    async start() {
      const snapshot = lifecycle.getSnapshotSync();
      if (snapshot.phase !== "signed_out" && snapshot.phase !== "authenticating") {
        throw new Error(messages.auth_attempt_stale({}, { locale: guestLocale }));
      }
      // Google button preparation already starts an attempt. The adapter
      // replaces it under the Cookie lock and rejects its late credentials.
      const result = await lifecycle.startGuestSession({
        expected: {
          authorityInstanceId: snapshot.authority.authorityInstanceId,
          expectedSessionId: null,
          generation: snapshot.generation,
        },
      });
      if (!result.ok) throw guestError(result.error.code);
    },
    subscribeImported: (listener) => lifecycle.subscribeGuestImported(listener),
  };

  return {
    apiBaseUrl: lifecycle.baseUrl,
    authenticator,
    guest,
    lifecycle,
    exchangeTelegramLaunch: (launch) => lifecycle.exchangeTelegramLaunch(launch),
    dispose() {
      cachedProduct = undefined;
      lifecycle.dispose();
    },
    getProductTransport() {
      const lease = lifecycle.getProductLease();
      if (!lease) {
        cachedProduct = undefined;
        return undefined;
      }
      if (cachedProduct && sameWebCookieProductLease(cachedProduct.lease, lease)) {
        return cachedProduct.transport;
      }

      const transport = webCookieProductTransport(lifecycle, lease);
      cachedProduct = { lease, transport };
      return transport;
    },
    initialize() {
      initialization ??= lifecycle
        .reconcile({ reason: "startup" })
        .then(() => undefined);
      return initialization;
    },
    recover() {
      return lifecycle.recover();
    },
  };
}

function sameWebCookieProductLease(
  left: WebCookieSessionProductLease,
  right: WebCookieSessionProductLease
) {
  return (
    left.authorityInstanceId === right.authorityInstanceId &&
    left.generation === right.generation &&
    left.sessionId === right.sessionId &&
    left.audience === right.audience &&
    left.cookieAuthorityId === right.cookieAuthorityId &&
    left.cookieGeneration === right.cookieGeneration &&
    left.signal === right.signal
  );
}

function webCookieProductTransport(
  lifecycle: WebCookieSessionAdapter,
  lease: WebCookieSessionProductLease
): CommaApiSessionTransport {
  return {
    credentials: "include",
    signal: lease.signal,
    applyHeaders(headers) {
      headers["x-comma-expected-auth-session-id"] = lease.sessionId;
      headers["x-comma-session-lifecycle-version"] = "1";
      headers["x-comma-session-transport"] = "cookie";
    },
    reportSessionRejection(status) {
      if (status === 401) {
        lifecycle.reportProductUnauthorized(lease);
      } else {
        lifecycle.reportProductSessionChanged(lease);
      }
    },
  };
}
