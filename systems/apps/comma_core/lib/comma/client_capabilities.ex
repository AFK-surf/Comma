defmodule Comma.ClientCapabilities do
  @moduledoc """
  What the client making a request says it is and what it can do, from its
  `x-comma-client` (`kind/platform/version`) and `x-comma-client-capabilities`
  (comma-separated names) headers.

  A client that sends neither, one built before they existed, can do nothing
  optional: a feature that needs a capability is not offered to it. A feature
  says what it needs in its definition's `ui`: `requires` (capability names, all
  needed) and `platforms` (the client platforms it is for).

  Internal callers that act for no client pass no client and see everything.
  """

  @client_kinds ~w(web electron android ios watch api ssh)
  @client_platforms ~w(android ios watchos windows macos linux)
  @max_header_bytes 512
  @max_capabilities 32

  defstruct kind: nil, platform: nil, version: nil, capabilities: MapSet.new()

  @type t :: %__MODULE__{
          kind: String.t() | nil,
          platform: String.t() | nil,
          version: String.t() | nil,
          capabilities: MapSet.t(String.t())
        }

  @doc "The client from its two headers' values (nil when absent)."
  @spec from_headers(String.t() | nil, String.t() | nil) :: t()
  def from_headers(client, capabilities) do
    {kind, platform, version} = identity(client)

    %__MODULE__{
      kind: kind,
      platform: platform,
      version: version,
      capabilities: capability_set(capabilities)
    }
  end

  @doc "Whether a definition (with its `ui`) is offered to this client."
  @spec allows?(t() | nil, map()) :: boolean()
  def allows?(nil, _definition), do: true

  def allows?(%__MODULE__{} = client, definition) when is_map(definition) do
    ui = if is_map(definition["ui"]), do: definition["ui"], else: %{}
    capable?(client, ui["requires"]) and on_platform?(client, ui["platforms"])
  end

  defp capable?(_client, nil), do: true

  defp capable?(client, required) when is_list(required),
    do: Enum.all?(required, &MapSet.member?(client.capabilities, &1))

  defp capable?(_client, _malformed), do: false

  defp on_platform?(_client, nil), do: true
  defp on_platform?(client, platforms) when is_list(platforms), do: client.platform in platforms
  defp on_platform?(_client, _malformed), do: false

  defp identity(value) when is_binary(value) and byte_size(value) <= @max_header_bytes do
    case value |> String.trim() |> String.split("/", parts: 3) do
      [kind, platform | rest] ->
        {member(kind, @client_kinds), member(platform, @client_platforms), version(rest)}

      [kind] ->
        {member(kind, @client_kinds), nil, nil}
    end
  end

  defp identity(_value), do: {nil, nil, nil}

  defp member(value, allowed) do
    value = String.downcase(String.trim(value))
    if value in allowed, do: value
  end

  defp version([version]) do
    version = String.trim(version)
    if Regex.match?(~r/\A[0-9A-Za-z.+-]{1,64}\z/, version), do: version
  end

  defp version(_rest), do: nil

  defp capability_set(value) when is_binary(value) and byte_size(value) <= @max_header_bytes do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, &1))
    |> Enum.take(@max_capabilities)
    |> MapSet.new()
  end

  defp capability_set(_value), do: MapSet.new()
end
