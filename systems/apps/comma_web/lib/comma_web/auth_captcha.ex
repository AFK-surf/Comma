defmodule CommaWeb.AuthCaptcha do
  @moduledoc "Public, credential-free presentation for one protected app action."

  import Plug.Conn

  def public_page?(%{method: "GET", request_path: "/v1/comma/auth/captcha"}), do: true
  def public_page?(_conn), do: false

  def serve(conn) do
    conn = fetch_query_params(conn)
    id = conn.query_params["challenge_id"]
    action = conn.query_params["action"]
    site_key = Comma.Auth.Abuse.Turnstile.site_key()

    cond do
      not (is_binary(id) and byte_size(id) in 1..200 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)) or
        action not in ["email_login", "registration"] or map_size(conn.query_params) != 2 ->
        send_resp(conn, 400, "Invalid security check.")

      not is_binary(site_key) or site_key == "" ->
        send_resp(conn, 503, "Security check is unavailable. Try again later.")

      true ->
        page(conn, id, action, site_key)
    end
  end

  defp page(conn, id, action, site_key) do
    config =
      Jason.encode!(%{id: id, action: action, siteKey: site_key})
      |> String.replace("<", "\\u003c")

    html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Security check</title></head><body><div id="challenge"></div><p id="status" role="status"></p>
    <script>
    const config=#{config};
    window.commaCaptchaFailed=()=>document.getElementById('status').textContent='The security check could not complete. Cancel and try again.';
    window.commaCaptchaReady=()=>turnstile.render('#challenge',{sitekey:config.siteKey,action:config.action,cData:config.id,
      callback:token=>window.parent.postMessage({type:'comma.captcha',challengeId:config.id,token},'*'),
      'error-callback':window.commaCaptchaFailed,'expired-callback':window.commaCaptchaFailed});
    </script>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=commaCaptchaReady&render=explicit" async defer onerror="commaCaptchaFailed()"></script>
    </body></html>
    """

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'unsafe-inline' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; connect-src https://challenges.cloudflare.com; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"
    )
    |> delete_resp_header("x-frame-options")
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
