defmodule SalixIM.ProviderRecipientIdentity do
  @moduledoc """
  Builds and renders the bounded provider-side identity that received an
  external IM message.

  The snapshot is presentation context only. Ingress derives it from the
  resolved connect and replaces any caller-supplied value; routing and
  authorization must continue to use their existing server-owned records.

  The hidden immutable Task-thread Participant-generation marker carried to
  the Conversation owner commit boundary is modeled in
  `tla/salix/SlackTaskThreadGenerationFence.tla`.
  """

  @metadata_key "recipient_im_identity"
  @trusted_request_key :trusted_provider_recipient_identity_v1
  @trusted_participant_incarnation_key :trusted_provider_participant_incarnation_v1
  @owner_field "owner_recipient_im_identity_v1"
  @field_limit 256
  @identity_fields ~w(provider display_name username user_id bot_id app_id status)
  @providers ~w(slack telegram feishu wechat imessage voice signal)

  @spec put(map(), map()) :: map()
  def put(metadata, connect) when is_map(metadata) and is_map(connect) do
    metadata = Map.drop(metadata, [@metadata_key, :recipient_im_identity])

    case {clean(metadata["provider"]), from_connect(connect)} do
      {provider, %{"provider" => provider} = identity} when provider != "" ->
        Map.put(metadata, @metadata_key, identity)

      _other ->
        metadata
    end
  end

  @doc false
  def trusted_request_key, do: @trusted_request_key

  @doc false
  def owner_field, do: @owner_field

  @doc "Moves a provider-authored identity out of legacy-fingerprinted metadata."
  @spec mark_trusted_provider_message(map()) :: map()
  def mark_trusted_provider_message(attrs) when is_map(attrs) do
    metadata = attrs |> Map.get("metadata", %{}) |> normalize_metadata()
    identity = from_metadata(metadata)
    metadata = Map.drop(metadata, [@metadata_key, :recipient_im_identity])

    attrs =
      attrs
      |> Map.put("metadata", metadata)
      |> Map.delete(@trusted_request_key)

    if is_map(identity), do: Map.put(attrs, @trusted_request_key, identity), else: attrs
  end

  @doc false
  def mark_trusted_participant_incarnation(attrs, payload_field, generation)
      when is_map(attrs) and is_binary(payload_field) and payload_field != "" and
             (is_nil(generation) or (is_binary(generation) and generation != "")),
      do: mark_trusted_participant_incarnation(attrs, payload_field, generation, %{})

  @doc false
  def mark_trusted_participant_incarnation(attrs, payload_field, generation, required_payload)
      when is_map(attrs) and is_binary(payload_field) and payload_field != "" and
             (is_nil(generation) or (is_binary(generation) and generation != "")) and
             is_map(required_payload) do
    Map.put(attrs, @trusted_participant_incarnation_key, %{
      "payload_field" => payload_field,
      "generation" => generation,
      "required_payload" => required_payload
    })
  end

  @doc false
  def take_trusted_participant_incarnation(attrs) when is_map(attrs) do
    marker? = Map.has_key?(attrs, @trusted_participant_incarnation_key)
    incarnation = attrs[@trusted_participant_incarnation_key]
    attrs = Map.delete(attrs, @trusted_participant_incarnation_key)

    cond do
      not marker? ->
        {:ok, attrs, nil}

      valid_participant_incarnation?(incarnation) ->
        {:ok, attrs, incarnation}

      true ->
        {:error, {:bad_request, "invalid trusted provider participant incarnation"}}
    end
  end

  @doc false
  @spec take_trusted_owner_identity(map(), map()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def take_trusted_owner_identity(attrs, participant)
      when is_map(attrs) and is_map(participant) do
    marker? = Map.has_key?(attrs, @trusted_request_key)
    identity = if marker?, do: sanitize_identity(attrs[@trusted_request_key])
    attrs = Map.delete(attrs, @trusted_request_key)

    cond do
      not marker? ->
        {:ok, attrs, nil}

      is_nil(identity) ->
        {:error, {:bad_request, "invalid trusted provider recipient identity"}}

      participant["actor_type"] != "provider" or
        attrs["actor_type"] not in ["provider_user", "provider_system"] or
        clean(participant["provider"]) != identity["provider"] or
        clean(attrs["provider"]) != identity["provider"] or
          clean(get_in(attrs, ["metadata", "provider"])) != identity["provider"] ->
        {:error, {:bad_request, "trusted provider recipient identity does not match sender"}}

      true ->
        {:ok, attrs, identity}
    end
  end

  @spec from_owner_record(map()) :: map() | nil
  def from_owner_record(%{@owner_field => identity}) when is_map(identity) do
    if valid_owner_identity?(identity), do: identity
  end

  def from_owner_record(_record), do: nil

  @doc false
  @spec valid_owner_identity?(term()) :: boolean()
  def valid_owner_identity?(nil), do: true

  def valid_owner_identity?(identity) when is_map(identity),
    do: sanitize_identity(identity) == identity

  def valid_owner_identity?(_identity), do: false

  @spec encoded_from_owner_record(map()) :: String.t()
  def encoded_from_owner_record(record) do
    case from_owner_record(record) do
      identity when is_map(identity) -> Jason.encode!(identity)
      nil -> ""
    end
  end

  @spec from_connect(map()) :: map() | nil
  def from_connect(%{"provider" => provider} = connect) when provider in @providers do
    provider
    |> identity_fields(connect)
    |> sanitize_identity()
  end

  def from_connect(_connect), do: nil

  @spec from_metadata(map()) :: map() | nil
  def from_metadata(%{
        "provider" => outer_provider,
        @metadata_key => %{"provider" => inner_provider} = identity
      }) do
    outer_provider = clean(outer_provider)
    inner_provider = clean(inner_provider)

    if outer_provider in @providers and inner_provider == outer_provider do
      sanitize_identity(identity)
    end
  end

  def from_metadata(_metadata), do: nil

  @spec encoded_from_metadata(map()) :: String.t()
  def encoded_from_metadata(metadata) do
    case from_metadata(metadata) do
      identity when is_map(identity) -> Jason.encode!(identity)
      nil -> ""
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp valid_participant_incarnation?(%{
         "payload_field" => field,
         "generation" => generation,
         "required_payload" => required_payload
       }) do
    is_binary(field) and field != "" and
      (is_nil(generation) or (is_binary(generation) and generation != "")) and
      is_map(required_payload) and
      Enum.all?(required_payload, fn {key, value} ->
        is_binary(key) and key != "" and
          (is_binary(value) or is_boolean(value) or is_integer(value))
      end)
  end

  defp valid_participant_incarnation?(_incarnation), do: false

  defp identity_fields("slack", connect) do
    username = clean(connect["bot_username"])

    %{
      "provider" => "slack",
      "display_name" => first_nonblank([connect["app_name"], username]),
      "username" => username,
      "user_id" => connect["bot_user_id"],
      "bot_id" => connect["bot_id"],
      "app_id" => connect["app_id"]
    }
  end

  defp identity_fields("telegram", connect) do
    username = clean(connect["bot_username"])

    %{
      "provider" => "telegram",
      "display_name" => first_nonblank([connect["bot_display_name"], username]),
      "username" => username,
      "user_id" => connect["bot_user_id"]
    }
  end

  defp identity_fields("imessage", connect) do
    %{
      "provider" => "imessage",
      "display_name" => connect["bot_display_name"],
      "user_id" => connect["bot_user_id"]
    }
  end

  defp identity_fields("feishu", connect) do
    %{
      "provider" => "feishu",
      "display_name" => connect["app_name"],
      "user_id" => connect["bot_open_id"],
      "app_id" => connect["app_id"]
    }
  end

  # A voice connect has no bot account; the carrier line is per call.
  defp identity_fields("voice", _connect) do
    %{"provider" => "voice", "display_name" => "Comma voice"}
  end

  # A Signal connect can bind peers on several Comma Signal accounts.
  defp identity_fields("signal", _connect) do
    %{"provider" => "signal", "display_name" => "Comma Signal"}
  end

  defp identity_fields("wechat", _connect) do
    %{"provider" => "wechat", "status" => "unavailable"}
  end

  defp sanitize_identity(identity) when is_map(identity) do
    identity
    |> Map.take(@identity_fields)
    |> Enum.map(fn {key, value} -> {key, clean(value)} end)
    |> Enum.reject(fn {_key, value} -> value == "" end)
    |> Map.new()
    |> case do
      %{"provider" => provider} = sanitized when provider in @providers -> sanitized
      _other -> nil
    end
  end

  defp first_nonblank(values) do
    values
    |> Enum.map(&clean/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp clean(value) when is_binary(value) do
    value
    |> String.replace(~r/[\p{Cc}\p{Cf}]+/u, " ")
    |> String.trim()
    |> String.slice(0, @field_limit)
  end

  defp clean(value) when is_integer(value), do: value |> Integer.to_string() |> clean()
  defp clean(_value), do: ""
end
