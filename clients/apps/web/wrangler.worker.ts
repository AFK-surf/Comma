interface Env {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
}

const commaApiPrefix = "/v1";
const publicSharePath = /^\/s\/[^/]+\/?$/;

// A public Task Share link: the token stays out of referrers and indexes.
async function servePublicShare(request: Request, env: Env): Promise<Response> {
  let page = await env.ASSETS.fetch(
    new Request(new URL("/share.html", request.url), request)
  );
  // Asset HTML handling may canonicalize the file name with a redirect. Follow
  // it here: the browser must stay on /s/<token>, which carries the token.
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

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    const pathname = new URL(request.url).pathname;
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
      return servePublicShare(request, env);
    }
    return env.ASSETS.fetch(request);
  },
};
