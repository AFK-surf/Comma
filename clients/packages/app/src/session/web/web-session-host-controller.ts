import type { CommaLocale } from "@comma/i18n";
import type { CommaApiSessionTransport } from "../../api";
import type { SessionHostController } from "../controller";
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

  return {
    apiBaseUrl: lifecycle.baseUrl,
    authenticator,
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
