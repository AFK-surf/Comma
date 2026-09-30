interface Env {
  ASSETS: {
    fetch(request: Request): Promise<Response>;
  };
}

const commaApiPrefix = "/v1";

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

    return env.ASSETS.fetch(request);
  },
};
