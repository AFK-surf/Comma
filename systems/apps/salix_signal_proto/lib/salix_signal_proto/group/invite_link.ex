defmodule SalixSignalProto.Group.InviteLink do
  @moduledoc """
  Group invite links (CRS-09b section 8):
  `https://signal.group/#<base64url-no-padding(invite link message)>`, where
  the message is `{1: {1: master key, 2: link password}}`.

  Parsing accepts the scheme `https` or `sgnl`, the host `signal.group` in
  any case, an empty path or `/`, and a fragment in either base64 alphabet
  with or without padding.
  """

  alias SalixSignalProto.Group.State
  alias SalixSignalProto.Group.Wire

  @doc "Builds the invite link URL."
  @spec build(<<_::256>>, binary()) :: String.t()
  def build(<<_::binary-size(32)>> = master_key, password) when is_binary(password) do
    message =
      Protobuf.encode(%Wire.InviteLink{
        v1: %Wire.InviteLink.V1{master_key: master_key, password: password}
      })

    "https://signal.group/#" <> Base.url_encode64(message, padding: false)
  end

  @doc """
  Parses an invite link URL into `{master_key, password}`. Returns
  `{:error, :unknown_version}` for a link without version-1 contents and
  `{:error, :invalid}` for anything else that is not a group link.
  """
  @spec parse(String.t()) :: {:ok, {<<_::256>>, binary()}} | {:error, :invalid | :unknown_version}
  def parse(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host, path: path, fragment: fragment} when is_binary(fragment) <-
           URI.parse(url),
         true <- scheme in ["https", "sgnl"],
         true <- is_binary(host) and String.downcase(host) == "signal.group",
         true <- path in [nil, "", "/"],
         {:ok, bytes} <- decode_fragment(fragment),
         {:ok, %Wire.InviteLink{} = link} <- State.decode(Wire.InviteLink, bytes) do
      case link.v1 do
        %Wire.InviteLink.V1{master_key: <<_::binary-size(32)>> = key, password: password} ->
          {:ok, {key, password}}

        nil ->
          {:error, :unknown_version}

        _ ->
          {:error, :invalid}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  def parse(_url), do: {:error, :invalid}

  defp decode_fragment(fragment) do
    normalized =
      fragment
      |> String.replace("+", "-")
      |> String.replace("/", "_")
      |> String.trim_trailing("=")

    Base.url_decode64(normalized, padding: false)
  end

  @doc "The password as the `<pw>` path and query element: base64url without padding."
  @spec encode_password(binary()) :: String.t()
  def encode_password(password), do: Base.url_encode64(password, padding: false)

  @doc "A new 16-byte link password."
  @spec new_password() :: binary()
  def new_password, do: :crypto.strong_rand_bytes(16)
end
