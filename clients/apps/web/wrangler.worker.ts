import {
  miniAppRuntimeCsp,
  miniAppRuntimeDocument,
  miniAppWebRuntimePath,
} from "@comma/chat-contract/mini-app-runtime";

import androidAssetLinks from "./assetlinks.json";

interface Env {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
}

const commaApiPrefix = "/v1";
const publicSharePath = /^\/s\/[^/]+\/?$/;
const collabGuestPath = /^\/c\/[^/]+\/?$/;
const miniAppLinkPath = /^\/a\/[^/]+\/?$/;
// Only production is for search. Staging and preview hosts stay out of indexes.
const indexedHost = "app.comma.surf";
const appLinkHosts = new Set([indexedHost, "app-staging.comma.surf"]);

// The configured Apple signing team and phone bundle own /a/ links. Apple verifies the signed App's association.
const appAssociation = {
  applinks: {
    details: [{ appIDs: ["D9AAN3VJK8.surf.comma.ios"], components: [{ "/": "/a/*" }] }],
  },
};

// A public Task Share link or external guest collaboration link: the token stays out of referrers and indexes.
async function serveTokenPage(
  request: Request,
  env: Env,
  assetPath: "/share.html" | "/collab.html"
): Promise<Response> {
  let page = await env.ASSETS.fetch(
    new Request(new URL(assetPath, request.url), request)
  );
  // Asset HTML handling may canonicalize the file name with a redirect. Follow
  // it here: the browser must stay on /s/<token> or /c/<token>, which carries the token.
  const location = page.headers.get("location");
  if (page.status >= 300 && page.status < 400 && location) {
    page = await env.ASSETS.fetch(new Request(new URL(location, request.url), request));
  }
  const response = new Response(page.body, page);
  response.headers.set("cache-control", "no-store");
  response.headers.set("referrer-policy", "no-referrer");
  response.headers.set("x-robots-tag", "noindex");
  return response;
}

// The Comma app runtime (design AFK-surf/Cue#4070 §7.1): one fixed document
// that a sandboxed frame loads. App content reaches it only over the frame's port.
function serveMiniAppRuntime(): Response {
  return new Response(miniAppRuntimeDocument(), {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": miniAppRuntimeCsp,
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

// A Comma app link opens the normal app, which reads the token from the path.
// The token stays out of referrers and indexes.
async function serveMiniAppLink(request: Request, env: Env): Promise<Response> {
  const page = await env.ASSETS.fetch(new Request(new URL("/", request.url), request));
  const response = new Response(page.body, page);
  response.headers.set("cache-control", "no-store");
  response.headers.set("referrer-policy", "no-referrer");
  response.headers.set("x-robots-tag", "noindex");
  return response;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const response = await serve(request, url.pathname, env);
    if (url.hostname === indexedHost) return response;
    const hidden = new Response(response.body, response);
    hidden.headers.set("x-robots-tag", "noindex");
    return hidden;
  },
};

function serve(request: Request, pathname: string, env: Env): Promise<Response> {
  const android = pathname === "/.well-known/assetlinks.json";
  if (android || pathname === "/.well-known/apple-app-site-association") {
    const { hostname } = new URL(request.url);
    if (android ? hostname !== indexedHost : !appLinkHosts.has(hostname))
      return Promise.resolve(new Response(null, { status: 404 }));
    if (request.method !== "GET" && request.method !== "HEAD")
      return Promise.resolve(
        new Response(null, { status: 405, headers: { allow: "GET, HEAD" } })
      );
    const body = android
      ? JSON.stringify(androidAssetLinks, null, 2)
      : JSON.stringify(appAssociation);
    return Promise.resolve(
      new Response(request.method === "HEAD" ? null : body, {
        headers: {
          "content-type": "application/json",
          "cache-control": "public, max-age=3600",
          "x-content-type-options": "nosniff",
        },
      })
    );
  }
  if (pathname === commaApiPrefix || pathname.startsWith(`${commaApiPrefix}/`)) {
    return Promise.resolve(
      Response.json(
        { error: "direct_api_origin_required" },
        {
          headers: { "cache-control": "no-store" },
          status: 404,
        }
      )
    );
  }
  if (publicSharePath.test(pathname)) {
    return serveTokenPage(request, env, "/share.html");
  }
  if (collabGuestPath.test(pathname)) {
    return serveTokenPage(request, env, "/collab.html");
  }
  if (pathname === miniAppWebRuntimePath) {
    return Promise.resolve(serveMiniAppRuntime());
  }
  if (miniAppLinkPath.test(pathname)) {
    return serveMiniAppLink(request, env);
  }
  return env.ASSETS.fetch(request);
}
