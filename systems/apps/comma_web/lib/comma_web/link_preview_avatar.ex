defmodule CommaWeb.LinkPreviewAvatar do
  @moduledoc false

  # The avatar of a person on a link preview card: a pull request's author, an
  # issue's assignee, a message's author, a file's owner. The preview names it
  # by `avatarRef`, a signed reference to the provider's own avatar URL, and
  # the client reads the image through `GET /v1/comma/link-preview-avatars/:ref`.
  # This server fetches it: a web client makes no provider request of its own,
  # and the desktop's own pinned loader cannot reach the avatar hosts through a
  # proxy.
  #
  # The endpoint would otherwise be a proxy for any URL a caller composes, so
  # a reference is signed and names only a URL this server itself put on a
  # preview, on an avatar host a supported provider serves. The host is
  # resolved to a public address and pinned (`SalixMCP.URLPolicy`), no
  # redirect is followed, and only a bounded image body is answered.

  @key_context "comma-link-preview-avatar-v1"
  @max_url_bytes 2_048
  @max_body_bytes 1_048_576
  @timeout_ms 5_000
  @media_types ~w(image/png image/jpeg image/gif image/webp)

  # GitHub, Linear, Slack (and the Gravatar it serves) and Google (Drive).
  @hosts ~w(
    avatars.githubusercontent.com
    public-files.linear.app
    avatars.linear.app
    uploads.linear.app
    avatars.slack-edge.com
    a.slack-edge.com
    secure.gravatar.com
  )
  @host_suffixes ~w(.googleusercontent.com)

  @doc "The signed reference of `url`; nil for no URL, or one Comma does not read."
  @spec ref(String.t() | nil) :: String.t() | nil
  def ref(url) when is_binary(url) do
    with true <- readable?(url),
         {:ok, key} <- signing_key() do
      "v1." <>
        Base.url_encode64(url, padding: false) <>
        "." <> Base.url_encode64(signature(key, url), padding: false)
    else
      _ -> nil
    end
  end

  def ref(_url), do: nil

  @doc "The URL a reference names, when this server signed it."
  @spec url(String.t()) :: {:ok, String.t()} | :error
  def url("v1." <> rest) when is_binary(rest) do
    with [encoded, encoded_signature] <- String.split(rest, ".", parts: 2),
         {:ok, url} <- Base.url_decode64(encoded, padding: false),
         {:ok, given} <- Base.url_decode64(encoded_signature, padding: false),
         {:ok, key} <- signing_key(),
         true <- Plug.Crypto.secure_compare(given, signature(key, url)),
         true <- readable?(url) do
      {:ok, url}
    else
      _ -> :error
    end
  end

  def url(_ref), do: :error

  @doc "The image a reference names: its media type and bytes."
  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | {:error, :not_found}
  def fetch(ref) do
    with {:ok, url} <- url(ref),
         {:ok, target} <- url_policy().public_http_target(url),
         {:ok, %Req.Response{status: 200} = response} <- Req.request(request_options(target)),
         body when is_binary(body) and body != "" <- response.body,
         media_type when media_type in @media_types <- media_type(response) do
      {:ok, media_type, body}
    else
      _ -> {:error, :not_found}
    end
  end

  defp request_options(target) do
    Keyword.merge(
      [
        method: :get,
        url: target.url,
        headers: %{
          "host" => target.host_header,
          "accept" => Enum.join(@media_types, ", "),
          "user-agent" => "Comma"
        },
        connect_options: Keyword.put(target.connect_options, :timeout, @timeout_ms),
        inet6: target.inet6,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: @timeout_ms,
        pool_timeout: @timeout_ms,
        into: &collect_bounded_body/2
      ],
      SystemsRuntime.get_env(:comma_web, :link_preview_avatar_http_options, [])
    )
  end

  # The body up to its bound; past it the read stops and the response has none.
  defp collect_bounded_body({:data, data}, {request, response}) do
    body = if is_binary(response.body), do: response.body <> data, else: data

    if byte_size(body) > @max_body_bytes,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: body}}}
  end

  defp media_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] ->
        value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

      _ ->
        nil
    end
  end

  defp readable?(url) when byte_size(url) > @max_url_bytes, do: false

  defp readable?(url) do
    uri = URI.parse(url)

    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and uri.port in [nil, 443] and allowed_host?(String.downcase(uri.host))
  end

  defp allowed_host?(host) do
    host in @hosts or Enum.any?(@host_suffixes, &String.ends_with?(host, &1))
  end

  defp signature(key, url), do: :crypto.mac(:hmac, :sha256, key, url)

  defp signing_key do
    secret =
      SystemsRuntime.get_env(:comma_web, :link_preview_avatar_secret) ||
        SystemsRuntime.get_env(:comma_web, :api_token) ||
        SystemsRuntime.get_env(:salix_web, :api_token)

    if is_binary(secret) and String.trim(secret) != "",
      do: {:ok, :crypto.mac(:hmac, :sha256, secret, @key_context)},
      else: {:error, :not_configured}
  end

  # `SalixMCP.URLPolicy`, or a test's stand-in.
  defp url_policy,
    do: SystemsRuntime.get_env(:comma_web, :link_preview_avatar_url_policy, SalixMCP.URLPolicy)
end
