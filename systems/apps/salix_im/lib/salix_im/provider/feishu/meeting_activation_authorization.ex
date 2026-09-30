defmodule SalixIM.Provider.Feishu.MeetingActivationAuthorization do
  @moduledoc false

  alias SalixIM.Conversations
  alias SalixIM.Provider.Feishu.{API, MeetingActivationRef}

  @max_source_ids 64
  @max_activation_refs 64
  @max_source_id_bytes 512
  @max_total_ref_bytes 1_024 * 1_024
  @authorization_error "meeting activation is not authorized for this Feishu target"

  def authorize(scope, connect, api, params) do
    case activation_grants(scope.group_id, SalixIM.Provider.current_tool_context()) do
      {:ok, []} -> :ok
      {:ok, grants} -> authorize_grants(connect, grants, api, stringify(params || %{}))
      {:error, _reason} -> {:error, @authorization_error}
    end
  end

  @doc false
  def provenance_for_tool_context(group_id, context) do
    with {:ok, grants} <- activation_grants(trim(group_id), context) do
      grants
      |> Enum.map(&Map.take(&1, ["connect_id", "ref"]))
      |> provenance_from_candidates()
    end
  end

  @doc false
  def provenance_for_conversation(%{} = conversation) do
    with {:ok, candidates} <- inherited_activation_candidates(conversation) do
      provenance_from_candidates(candidates)
    end
  end

  def provenance_for_conversation(_conversation), do: {:error, :invalid_activation_context}

  @doc false
  def merge_provenance(provenances) when is_list(provenances) do
    provenances
    |> Enum.reduce_while({:ok, []}, fn provenance, {:ok, acc} ->
      provenance = stringify(provenance || %{})

      case activation_candidate_list(
             provenance["meeting_activation_refs"],
             :invalid_message_activation_refs
           ) do
        {:ok, candidates} -> {:cont, {:ok, acc ++ candidates}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candidates} -> provenance_from_candidates(candidates)
      error -> error
    end
  end

  def merge_provenance(_provenances), do: {:error, :invalid_activation_context}

  @doc false
  def delivery_reply_targets(%{} = record) do
    group_id = trim(record["agent_group_id"])
    metadata = stringify(record["message_metadata"] || %{})
    conversation = %{"source_refs" => record["conversation_source_refs"] || %{}}

    with true <- group_id != "",
         {:ok, direct} <-
           direct_activation_candidates(metadata, trim(record["source_message_id"])),
         {:ok, inherited} <- inherited_activation_candidates(conversation),
         candidates = Enum.uniq(direct ++ inherited),
         true <- valid_candidate_budget?(candidates),
         {:ok, grants} <- decode_candidates(group_id, candidates) do
      {:ok,
       Enum.map(grants, fn %{"connect_id" => connect_id, "grant" => grant} ->
         %{
           "connect_id" => connect_id,
           "target" => stringify(grant["target"] || %{}),
           "allowed_mentions" =>
             grant
             |> Map.get("allowed_mentions", [])
             |> List.wrap()
             |> Enum.filter(&is_map/1)
         }
       end)}
    else
      false -> {:error, :invalid_activation_context}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_activation_context}
    end
  end

  def delivery_reply_targets(_record), do: {:error, :invalid_activation_context}

  defp group_conversation_message_id("groupconv:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [conversation_id, message_id, _participant_id]
      when conversation_id != "" and message_id != "" ->
        {conversation_id, message_id}

      _ ->
        :invalid
    end
  end

  defp group_conversation_message_id(_source_id), do: nil

  defp activation_grants(group_id, context) do
    with {:ok, source_ids} <- source_message_ids(context) do
      cond do
        source_ids == [] ->
          {:ok, []}

        group_id == "" ->
          {:error, :invalid_activation_context}

        true ->
          with {:ok, candidates} <- activation_candidates(group_id, source_ids, context),
               true <- valid_candidate_budget?(candidates) do
            decode_candidates(group_id, candidates)
          else
            false -> {:error, :invalid_activation_context}
            {:error, _reason} = error -> error
            _ -> {:error, :invalid_activation_context}
          end
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp source_message_ids(context) when is_map(context) do
    values =
      List.wrap(context["source_message_ids"] || context[:source_message_ids]) ++
        [context["source_message_id"] || context[:source_message_id]]

    values = Enum.reject(values, &(&1 in [nil, ""]))

    cond do
      not Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= @max_source_id_bytes)) ->
        {:error, :invalid_source_message_id}

      true ->
        source_ids = Enum.uniq(values)

        if length(source_ids) <= @max_source_ids,
          do: {:ok, source_ids},
          else: {:error, :activation_source_budget_exhausted}
    end
  end

  defp source_message_ids(_context), do: {:error, :invalid_activation_context}

  defp activation_candidates(group_id, source_ids, context) do
    with {:ok, conversation_candidates} <-
           conversation_activation_candidates(group_id, source_ids),
         {:ok, direct_candidates} <-
           trusted_origin_activation_candidates(group_id, source_ids, context) do
      {:ok, Enum.uniq(conversation_candidates ++ direct_candidates)}
    end
  end

  defp conversation_activation_candidates(group_id, source_ids) do
    Enum.reduce_while(source_ids, {:ok, []}, fn source_id, {:ok, acc} ->
      case group_conversation_message_id(source_id) do
        {conversation_id, message_id} ->
          case source_activation_candidates(group_id, conversation_id, message_id) do
            {:ok, candidates} -> {:cont, {:ok, acc ++ candidates}}
            {:error, _reason} = error -> {:halt, error}
          end

        :invalid ->
          {:halt, {:error, :invalid_group_conversation_source}}

        nil ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.uniq(candidates)}
      error -> error
    end
  end

  defp trusted_origin_activation_candidates(group_id, source_ids, context) do
    source_ids = MapSet.new(source_ids)

    activation_source_ids =
      source_ids
      |> Enum.filter(&String.starts_with?(&1, "meeting-activation:"))
      |> MapSet.new()

    origins = trusted_origins(context)

    origins
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn origin, {:ok, acc, matched} ->
      source_id = trim(origin["source_message_id"])

      cond do
        source_id == "" or not MapSet.member?(source_ids, source_id) ->
          {:cont, {:ok, acc, matched}}

        trim(origin["agent_group_id"]) != group_id ->
          {:halt, {:error, :invalid_activation_origin_scope}}

        true ->
          metadata =
            origin
            |> Map.get("provider_context", %{})
            |> stringify()
            |> Map.put("provider", trim(origin["provider"]))

          case direct_activation_candidates(metadata, source_id) do
            {:ok, candidates} ->
              matched =
                if candidates != [] and MapSet.member?(activation_source_ids, source_id),
                  do: MapSet.put(matched, source_id),
                  else: matched

              {:cont, {:ok, acc ++ candidates, matched}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, candidates, matched} ->
        if MapSet.subset?(activation_source_ids, matched),
          do: {:ok, Enum.uniq(candidates)},
          else: {:error, :missing_activation_origin}

      error ->
        error
    end
  end

  defp trusted_origins(context) when is_map(context) do
    (List.wrap(context["trusted_origins"] || context[:trusted_origins]) ++
       [context["trusted_origin"] || context[:trusted_origin]])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify/1)
    |> Enum.uniq()
  end

  defp trusted_origins(_context), do: []

  defp source_activation_candidates(group_id, conversation_id, message_id) do
    with {:ok, conversation} <-
           Conversations.get_group_conversation(group_id, conversation_id),
         {:ok, message} <-
           Conversations.get_group_conversation_message(
             group_id,
             conversation_id,
             message_id
           ),
         {:ok, direct} <- direct_activation_candidate(message),
         {:ok, inherited} <- inherited_activation_candidates(conversation) do
      {:ok, direct ++ inherited}
    else
      {:error, reason} -> {:error, {:activation_context_unavailable, reason}}
    end
  end

  defp direct_activation_candidate(message) do
    metadata = stringify(message["metadata"] || %{})
    source_id = trim(message["source_message_id"])

    direct_activation_candidates(metadata, source_id)
  end

  defp direct_activation_candidates(metadata, source_id) do
    provider = trim(metadata["provider"])
    event_type = trim(metadata["event_type"])
    ref = metadata["meeting_activation_ref"]
    connect_id = trim(metadata["connect_id"])

    activation? =
      provider == "feishu" and
        (event_type == "meeting_summary" or String.starts_with?(source_id, "meeting-activation:"))

    direct_result =
      cond do
        activation? -> candidate(connect_id, ref)
        not is_nil(ref) -> {:error, :orphaned_meeting_activation_ref}
        true -> {:ok, []}
      end

    with {:ok, direct} <- direct_result,
         {:ok, transitive} <-
           activation_candidate_list(
             metadata["meeting_activation_refs"],
             :invalid_message_activation_refs
           ) do
      {:ok, direct ++ transitive}
    end
  end

  defp inherited_activation_candidates(conversation) do
    source_refs = stringify(conversation["source_refs"] || %{})

    activation_candidate_list(
      source_refs["meeting_activation_refs"],
      :invalid_inherited_activation_refs
    )
  end

  defp activation_candidate_list(nil, _reason), do: {:ok, []}

  defp activation_candidate_list(refs, reason)
       when is_list(refs) and length(refs) <= @max_activation_refs do
    Enum.reduce_while(refs, {:ok, []}, fn
      %{} = item, {:ok, acc} ->
        case candidate(trim(item["connect_id"]), item["ref"]) do
          {:ok, [validated]} -> {:cont, {:ok, [validated | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _item, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp activation_candidate_list(_refs, reason), do: {:error, reason}

  defp candidate(connect_id, ref)
       when is_binary(ref) and ref != "" and is_binary(connect_id) and connect_id != "" do
    if byte_size(ref) <= MeetingActivationRef.max_ref_bytes(),
      do: {:ok, [%{"connect_id" => connect_id, "ref" => ref}]},
      else: {:error, :missing_or_invalid_activation_ref}
  end

  defp candidate(_connect_id, _ref), do: {:error, :missing_or_invalid_activation_ref}

  defp valid_candidate_budget?(candidates) when is_list(candidates) do
    length(candidates) <= @max_activation_refs and
      Enum.reduce_while(candidates, 0, fn
        %{"ref" => ref}, total when is_binary(ref) ->
          total = total + byte_size(ref)
          if total <= @max_total_ref_bytes, do: {:cont, total}, else: {:halt, :overflow}

        _candidate, _total ->
          {:halt, :overflow}
      end) != :overflow
  end

  defp valid_candidate_budget?(_candidates), do: false

  defp provenance_from_candidates(candidates) do
    candidates = Enum.uniq(candidates)

    cond do
      not valid_candidate_budget?(candidates) ->
        {:error, :activation_ref_budget_exhausted}

      candidates == [] ->
        {:ok, %{}}

      true ->
        {:ok, %{"meeting_activation_refs" => candidates}}
    end
  end

  defp decode_candidates(group_id, candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case decode_candidate(group_id, candidate) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      error -> error
    end
  end

  defp decode_candidate(group_id, %{"connect_id" => connect_id, "ref" => ref} = candidate) do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "feishu"),
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
    if expires_at >= System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp validate_expiry(_grant), do: {:error, :expired}

  defp validate_operation("feishu.reply_text"), do: :ok
  defp validate_operation(_api), do: {:error, :operation_not_authorized}

  defp validate_target(grant, params) do
    expected = grant["target"] || %{}

    checks = [
      {"message_id", params["message_id"]},
      {"chat_id", params["chat_id"]},
      {"chat_type", params["chat_type"]},
      {"thread_id", params["thread_id"]}
    ]

    if Enum.all?(checks, fn {key, actual} -> trim(actual) == trim(expected[key]) end) and
         truthy?(params["reply_in_thread"]) == truthy?(expected["reply_in_thread"]) do
      :ok
    else
      {:error, :target_mismatch}
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

  def ref_scope(group_id, connect_id), do: trim(group_id) <> ":" <> trim(connect_id)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), item} end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp truthy?(value), do: value in [true, 1, "1", "true", "TRUE", "yes", "on"]
end
