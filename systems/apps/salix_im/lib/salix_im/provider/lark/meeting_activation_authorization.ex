defmodule SalixIM.Provider.Lark.MeetingActivationAuthorization do
  @moduledoc """
  What a turn may send to Lark when one of its sources is a finished meeting
  (`meeting-activation:<meeting_id>`).

  Such a turn calls a Lark operation only with a grant (`MeetingActivationRef`)
  for the connect, and only the `lark.send_message` reply the grant names. A
  meeting source without a valid grant calls nothing. A turn with no meeting
  source is not restricted here.

  The grant is read from `lark_meeting_activation_ref` of the sealed origin of
  the meeting message. Lark has no grant that passes on to a derived
  Conversation message.
  """

  alias SalixIM.Provider.Lark.{API, MeetingActivationRef}

  @ref_key "lark_meeting_activation_ref"
  @max_total_ref_bytes 1_024 * 1_024
  @authorization_error "meeting activation is not authorized for this Lark target"

  @doc "The metadata key of a meeting message that carries its grant."
  @spec ref_key() :: String.t()
  def ref_key, do: @ref_key

  def authorize(scope, connect, api, params) do
    case activation_grants(scope.group_id, SalixIM.Provider.current_tool_context()) do
      {:ok, []} -> :ok
      {:ok, grants} -> authorize_grants(connect, grants, api, stringify(params || %{}))
      {:error, _reason} -> {:error, @authorization_error}
    end
  end

  def ref_scope(group_id, connect_id), do: trim(group_id) <> ":" <> trim(connect_id)

  defp activation_grants(group_id, context) do
    group_id = trim(group_id)

    with {:ok, candidates} <-
           origin_candidates(group_id, source_message_ids(context), context),
         true <- valid_candidate_budget?(candidates) do
      decode_candidates(group_id, candidates)
    else
      false -> {:error, :invalid_activation_context}
      {:error, _reason} = error -> error
    end
  end

  defp source_message_ids(context) do
    (List.wrap(context["source_message_ids"] || context[:source_message_ids]) ++
       [context["source_message_id"] || context[:source_message_id]])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # The grants of the sealed origins of this turn. Every meeting source must
  # bring one: a meeting of another provider, or one without a grant, fails.
  # An origin that brings a grant must be of this Group. An ordinary origin
  # is not looked at further.
  defp origin_candidates(group_id, source_ids, context) do
    source_ids = MapSet.new(source_ids)

    meeting_source_ids =
      source_ids
      |> Enum.filter(&String.starts_with?(&1, "meeting-activation:"))
      |> MapSet.new()

    context
    |> trusted_origins()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn origin, {:ok, acc, matched} ->
      source_id = trim(origin["source_message_id"])

      cond do
        source_id == "" or not MapSet.member?(source_ids, source_id) ->
          {:cont, {:ok, acc, matched}}

        true ->
          case origin_candidate(origin, source_id) do
            {:ok, []} ->
              {:cont, {:ok, acc, matched}}

            {:ok, found} ->
              if group_id != "" and trim(origin["agent_group_id"]) == group_id,
                do: {:cont, {:ok, acc ++ found, MapSet.put(matched, source_id)}},
                else: {:halt, {:error, :invalid_activation_origin_scope}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, candidates, matched} ->
        if MapSet.subset?(meeting_source_ids, matched),
          do: {:ok, Enum.uniq(candidates)},
          else: {:error, :missing_activation_origin}

      error ->
        error
    end
  end

  defp origin_candidate(origin, source_id) do
    context = stringify(origin["provider_context"] || %{})
    ref = context[@ref_key]

    cond do
      trim(origin["provider"]) == "lark" and String.starts_with?(source_id, "meeting-activation:") ->
        candidate(trim(context["connect_id"]), ref)

      not is_nil(ref) ->
        {:error, :orphaned_meeting_activation_ref}

      true ->
        {:ok, []}
    end
  end

  defp trusted_origins(context) when is_map(context) do
    (List.wrap(context["trusted_origins"] || context[:trusted_origins]) ++
       [context["trusted_origin"] || context[:trusted_origin]])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify/1)
    |> Enum.uniq()
  end

  defp candidate(connect_id, ref)
       when is_binary(ref) and ref != "" and is_binary(connect_id) and connect_id != "" do
    if byte_size(ref) <= MeetingActivationRef.max_ref_bytes(),
      do: {:ok, [%{"connect_id" => connect_id, "ref" => ref}]},
      else: {:error, :missing_or_invalid_activation_ref}
  end

  defp candidate(_connect_id, _ref), do: {:error, :missing_or_invalid_activation_ref}

  defp valid_candidate_budget?(candidates) do
    candidates |> Enum.map(&byte_size(&1["ref"])) |> Enum.sum() <= @max_total_ref_bytes
  end

  defp decode_candidates(group_id, candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case decode_candidate(group_id, candidate) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_candidate(group_id, %{"connect_id" => connect_id, "ref" => ref} = candidate) do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "lark"),
         {:ok, signing_key} <- API.resource_ref_signing_key(connect),
         {:ok, grant} <-
           MeetingActivationRef.decode(ref, ref_scope(group_id, connect_id), signing_key),
         :ok <- validate_expiry(grant) do
      {:ok, Map.put(candidate, "grant", grant)}
    end
  end

  defp authorize_grants(connect, grants, api, params) do
    connect_id = trim(connect["connect_id"])

    if Enum.any?(grants, fn
         %{"connect_id" => ^connect_id, "grant" => grant} ->
           authorize_grant(grant, api, params) == :ok

         _ ->
           false
       end) do
      :ok
    else
      {:error, @authorization_error}
    end
  end

  defp authorize_grant(grant, api, params) do
    with :ok <- validate_operation(api),
         :ok <- validate_target(grant, params),
         :ok <- validate_mentions(grant, params),
         do: :ok
  end

  defp validate_expiry(%{"expires_at" => expires_at}) when is_integer(expires_at) do
    if expires_at >= SystemsClock.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp validate_expiry(_grant), do: {:error, :expired}

  defp validate_operation("lark.send_message"), do: :ok
  defp validate_operation(_api), do: {:error, :operation_not_authorized}

  # The send must be the reply the grant names: the same chat and message,
  # in a thread or not as the grant says, to no single person and with no file.
  defp validate_target(grant, params) do
    expected = stringify(grant["target"] || %{})

    if trim(expected["chat_id"]) != "" and trim(expected["reply_to"]) != "" and
         trim(params["chat_id"]) == trim(expected["chat_id"]) and
         trim(params["reply_to"]) == trim(expected["reply_to"]) and
         trim(params["user_id"]) == "" and trim(params["path"]) == "" and
         reply_in_thread?(params, expected) == truthy?(expected["reply_in_thread"]) do
      :ok
    else
      {:error, :target_mismatch}
    end
  end

  # `lark.send_message` puts a reply into the thread of its message unless the
  # chat is private or the call says `reply_in_thread=false`.
  defp reply_in_thread?(params, expected) do
    case params["reply_in_thread"] do
      nil -> trim(expected["chat_type"]) != "p2p"
      value -> truthy?(value)
    end
  end

  defp validate_mentions(grant, params) do
    allowed =
      grant
      |> Map.get("allowed_mentions", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> MapSet.new(fn mention -> {trim(mention["user_id"]), trim(mention["name"])} end)

    mentions = List.wrap(params["mentions"])

    if not truthy?(params["mention_all"]) and
         Enum.all?(mentions, fn mention ->
           is_map(mention) and
             MapSet.member?(allowed, {trim(mention["user_id"]), trim(mention["name"])})
         end) do
      :ok
    else
      {:error, :mention_not_authorized}
    end
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "on"]
end
