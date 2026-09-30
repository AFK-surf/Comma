defmodule CommaWeb.TaskShareEndpoints do
  @moduledoc """
  HTTP surface for Task Shares (`Comma.TaskShares`).

  Owner routes live under `/v1/comma/groups` and use the normal Comma session. Public
  routes live under `/v1/comma/public/shares/`: the link token is the only authority,
  no cookie or bearer credential is read, and every request passes a
  fail-closed rate limit. Unknown, revoked, and no-longer-authorized links all
  return the same `404`.
  """

  import Plug.Conn

  @public_prefix "/v1/comma/public/shares/"

  @doc "True for the unauthenticated public share routes."
  @spec public_path?(String.t()) :: boolean()
  def public_path?(path) when is_binary(path), do: String.starts_with?(path, @public_prefix)
  def public_path?(_path), do: false

  @doc """
  Public share reads carry no credentials, so any web origin may call them.
  Preflights are answered here.
  """
  def put_public_cors(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET,OPTIONS")
    |> put_resp_header("access-control-max-age", "600")
    |> send_resp(204, "")
    |> halt()
  end

  def put_public_cors(conn), do: put_resp_header(conn, "access-control-allow-origin", "*")

  @doc "The owner's JSON view of a share, with its absolute public URL."
  def owner_json(view) do
    {token, view} = Map.pop(view, "token")
    Map.put(view, "url", share_url(token))
  end

  @doc "The public web URL of a share token."
  def share_url(token) do
    String.trim_trailing(Application.fetch_env!(:comma_web, :web_cookie_origin), "/") <>
      "/s/" <> token
  end

  ## Public routes

  def summary(conn, token) do
    with_rate_limit(conn, token, fn conn ->
      case Comma.TaskShares.public_summary(token) do
        {:ok, summary} -> send_public_json(conn, 200, summary)
        {:error, reason} -> public_error(conn, reason)
      end
    end)
  end

  def messages(conn, token) do
    with_rate_limit(conn, token, fn conn ->
      case Comma.TaskShares.public_messages(
             token,
             conn.query_params["after_seq"],
             conn.query_params["limit"]
           ) do
        {:ok, page} -> send_public_json(conn, 200, page)
        {:error, reason} -> public_error(conn, reason)
      end
    end)
  end

  def attachment(conn, token, seq, index) do
    with_rate_limit(conn, token, fn conn ->
      case Comma.TaskShares.public_attachment(token, seq, index) do
        {:ok, content_type, file_name, body} ->
          conn
          |> put_public_headers()
          |> put_resp_header("content-type", content_type)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-security-policy", "sandbox")
          |> put_resp_header(
            "content-disposition",
            "attachment; filename*=UTF-8''" <> URI.encode(file_name, &URI.char_unreserved?/1)
          )
          |> send_resp(200, body)

        {:error, reason} ->
          public_error(conn, reason)
      end
    end)
  end

  # A malformed token spends only the peer bucket, so random guesses cannot
  # create share buckets.
  defp with_rate_limit(conn, token, fun) do
    share_key = if Comma.TaskShares.valid_token?(token), do: token, else: :invalid

    case Comma.TaskShares.RateLimit.check(conn.remote_ip, share_key) do
      :allow ->
        fun.(conn)

      {:deny, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_public_json(429, %{error: "rate_limited"})

      {:unavailable, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_public_json(503, %{error: "temporarily_unavailable"})
    end
  end

  defp public_error(conn, :not_found), do: send_public_json(conn, 404, %{error: "not_found"})

  defp public_error(conn, :invalid_page),
    do: send_public_json(conn, 400, %{error: "invalid_page"})

  defp public_error(conn, _reason),
    do: send_public_json(conn, 503, %{error: "temporarily_unavailable"})

  defp send_public_json(conn, status, body) do
    conn
    |> put_public_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Revocation takes effect on the next request, so nothing may cache a read.
  defp put_public_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex")
  end
end
