defmodule SalixAgent.OnvifWsSecurity do
  @moduledoc """
  ONVIF authentication for `device.lan_request` (`auth.type:
  "onvif_ws_security"`): a WS-Security UsernameToken with a PasswordDigest,
  inserted into the request's SOAP Envelope.

  ONVIF devices such as TP-LINK cameras answer an unauthenticated call with
  `400 NotAuthorized` and send no HTTP challenge, so HTTP Basic and Digest do
  not apply. The digest is `Base64(SHA1(nonce <> created <> password))` with
  a fresh 16-byte nonce and the UTC time (ONVIF Core Specification 5.12.2,
  OASIS Username Token Profile 1.0). Salix computes it at dispatch from a
  saved `onvif_password`, so the password never enters the call or its
  result. The device compares `created` with its own clock and refuses a
  token far from it.
  """

  @wsse "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
  @wsu "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
  @digest_type "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
  @base64_type "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"

  @envelope ~r/<(?:([A-Za-z_][\w.-]*):)?Envelope(?=[\s>\/])[^>]*>/
  @security ~r/<(?:[A-Za-z_][\w.-]*:)?Security(?=[\s>\/])/

  @doc "The PasswordDigest of raw `nonce` bytes, the `created` text and `password`."
  def digest(nonce, created, password),
    do: :crypto.hash(:sha, nonce <> created <> password) |> Base.encode64()

  @doc """
  `body`, a SOAP Envelope, with a UsernameToken header for `username` and
  `password`. Returns `{:ok, body}`, `{:error, :not_soap}` or
  `{:error, :has_security}` when the body already carries a Security header.
  `opts` fixes `:nonce` (raw bytes) and `:created` (a `DateTime`) for tests.
  """
  def sign(body, username, password, opts \\ []) when is_binary(body) do
    cond do
      Regex.match?(@security, body) ->
        {:error, :has_security}

      match = Regex.run(@envelope, body, return: :index) ->
        nonce = Keyword.get_lazy(opts, :nonce, fn -> SystemsRuntime.Proc.random_bytes(16) end)

        created =
          opts
          |> Keyword.get_lazy(:created, &SystemsClock.utc_now/0)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()

        {:ok, insert(body, match, security(username, password, nonce, created))}

      true ->
        {:error, :not_soap}
    end
  end

  defp security(username, password, nonce, created) do
    ~s(<wsse:Security xmlns:wsse="#{@wsse}" xmlns:wsu="#{@wsu}">) <>
      "<wsse:UsernameToken>" <>
      "<wsse:Username>#{escape(username)}</wsse:Username>" <>
      ~s(<wsse:Password Type="#{@digest_type}">#{digest(nonce, created, password)}</wsse:Password>) <>
      ~s(<wsse:Nonce EncodingType="#{@base64_type}">#{Base.encode64(nonce)}</wsse:Nonce>) <>
      "<wsu:Created>#{created}</wsu:Created>" <>
      "</wsse:UsernameToken></wsse:Security>"
  end

  # Into the Envelope's Header, or a new Header right after the Envelope's
  # start tag, in the Envelope's own namespace prefix.
  defp insert(body, [{start, length} | prefix], security) do
    tag =
      case prefix do
        [{at, size}] when size > 0 -> binary_part(body, at, size) <> ":Header"
        _ -> "Header"
      end

    after_envelope = start + length
    head = binary_part(body, 0, after_envelope)
    rest = binary_part(body, after_envelope, byte_size(body) - after_envelope)
    header = Regex.compile!("<#{Regex.escape(tag)}(?=[\\s>/])[^>]*?(/?)>")

    case Regex.run(header, rest, return: :index) do
      [{at, size}, {_, 1}] ->
        open = binary_part(rest, at, size - 2) <> ">"
        splice(head, rest, at, size, open <> security <> "</#{tag}>")

      [{at, size}, _] ->
        splice(head, rest, at, size, binary_part(rest, at, size) <> security)

      nil ->
        head <> "<#{tag}>" <> security <> "</#{tag}>" <> rest
    end
  end

  defp splice(head, rest, at, size, replacement) do
    head <>
      binary_part(rest, 0, at) <>
      replacement <> binary_part(rest, at + size, byte_size(rest) - at - size)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
