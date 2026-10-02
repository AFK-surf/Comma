defmodule SalixIM.ConversationMessage do
  @moduledoc """
  Pure contract for conversation message validation, identity, and delivery.

  This module has no owner lifecycle or storage responsibility. Conversation
  owners use it before committing a message fact; participant owners use the
  persisted result without reinterpreting product roles or message kinds.

  Messages enter through explicit provider send operations. Draft ownership is
  transient Participant state and is not part of this contract.
  """

  alias SalixIM.ProviderRecipientIdentity
  alias SalixStore.{Crypto, Ids}

  require Logger

  @message_kinds ~w(message app_request app_event)
  @owner_inline_task_refs_v1_field "owner_inline_task_refs_v1"
  @inline_task_ref_limit SalixIM.ConversationLimits.inline_task_ref_limit()
  @delivery_filter_limit SalixIM.ConversationLimits.delivery_filter_limit()
  @mention_limit SalixIM.ConversationLimits.delivery_filter_limit()
  @max_local_file_refs 50
  @max_local_file_bytes 512 * 1024 * 1024
  @max_local_file_aggregate_bytes 1024 * 1024 * 1024
  @local_file_ref_pattern ~r/^lfi1_[A-Za-z0-9_-]{43}$/
  @local_file_allowed_keys ~w(type local_file_ref display_name size media_type)
  # A whole line that is only one inline Task marker is never renderable: the
  # clients build inline Task chips from structured `conversation_ref` blocks
  # and from user-authored `[title](comma:task/<id>)` links, so a raw marker line
  # reaches the reader as literal text.
  @agent_text_marker_pattern ~r/^\{comma:(?:task|conversation)\/([A-Za-z0-9][A-Za-z0-9._-]*)\}$/u
  @agent_text_marker_enforcement_key :agent_text_marker_enforcement

  @spec validate(map()) :: {:ok, map()} | {:error, term()}
  def validate(attrs) when is_map(attrs) do
    kind = attrs["kind"] || "message"

    cond do
      kind not in @message_kinds ->
        {:error, {:bad_request, "invalid IM message kind"}}

      not (is_nil(attrs["metadata"]) or is_map(attrs["metadata"])) ->
        {:error, {:bad_request, "invalid IM message metadata"}}

      not valid_mentions_shape?(attrs["mentions"]) ->
        {:error, {:bad_request, "invalid IM message mentions"}}

      not is_nil(attrs["reply_to_message_id"]) and
          not Ids.valid_message_id?(attrs["reply_to_message_id"]) ->
        {:error, {:bad_request, "reply_to_message_id must be a canonical message ID"}}

      not is_nil(attrs["thread_root_message_id"]) and
          not Ids.valid_message_id?(attrs["thread_root_message_id"]) ->
        {:error, {:bad_request, "thread_root_message_id must be a canonical message ID"}}

      true ->
        with {:ok, content} <- validate_content(kind, attrs["content"]) do
          {:ok, attrs |> Map.put("kind", kind) |> Map.put("content", content)}
        end
    end
  end

  def validate(_attrs), do: {:error, {:bad_request, "invalid request body"}}

  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{"metadata" => %{"billing_context" => _}}),
    do: {:error, {:bad_request, "billing_context is delivery-only"}}

  def prepare(%{"metadata" => %{billing_context: _}}),
    do: {:error, {:bad_request, "billing_context is delivery-only"}}

  def prepare(attrs) do
    with {:ok, attrs} <- validate(attrs),
         :ok <- reject_owner_identity(attrs),
         :ok <- reject_agent_text_markers(attrs) do
      {:ok, attrs}
    end
  end

  @spec build(map(), map(), integer()) :: map()
  def build(attrs, owner_fields, created_at)
      when is_map(attrs) and is_map(owner_fields) and is_integer(created_at) do
    common_fields = %{
      "message_id" => Ids.new_message_id(),
      "request_identity" => request_identity(attrs),
      "idempotency_key" => attrs["idempotency_key"],
      "client_request_id" => attrs["client_request_id"],
      "source_message_id" => attrs["source_message_id"],
      "reply_to_message_id" => attrs["reply_to_message_id"],
      "kind" => attrs["kind"],
      "content" => attrs["content"],
      "metadata" => attrs["metadata"] || %{},
      "mentions" => attrs["mentions"],
      "delivery_filter" => attrs["delivery_filter"],
      "created_at" => attrs["created_at"] || created_at
    }

    message =
      owner_fields
      |> Map.merge(common_fields)
      |> Map.put("agent_input", attrs[:agent_input])
      |> Map.put("agent_redelivery", attrs[:agent_redelivery])
      |> Map.put("provider_effect", attrs[:provider_effect])
      |> Map.put("provider_status", attrs[:provider_status])
      |> Map.put("platform_message", attrs[:platform_message])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    message = Map.put(message, "request_fingerprint", request_fingerprint(message))

    message =
      case attrs[:default_delivery_filter] do
        %{} = filter -> Map.put_new(message, "delivery_filter", filter)
        _ -> message
      end

    # The request fingerprint describes caller input. Apply the server-selected
    # reply target afterward so retries retain the first committed Message,
    # including Messages written before automatic association.
    case attrs[:default_reply_to_message_id] do
      target when is_binary(target) -> Map.put_new(message, "reply_to_message_id", target)
      _ -> message
    end
  end

  @spec validate_content(String.t(), term()) :: {:ok, list()} | {:error, term()}
  def validate_content("app_event", nil), do: {:ok, []}
  def validate_content("app_event", []), do: {:ok, []}

  def validate_content(_kind, nil),
    do: {:error, {:bad_request, "content is required"}}

  def validate_content(kind, content) when is_binary(content) do
    if String.trim(content) == "" and kind != "app_event" do
      {:error, {:bad_request, "content is required"}}
    else
      {:ok, [%{"type" => "text", "text" => content}]}
    end
  end

  def validate_content(_kind, content) when is_list(content) do
    content = Enum.map(content, &coerce_text_block/1)

    cond do
      content == [] ->
        {:error, {:bad_request, "content is required"}}

      not Enum.all?(content, &(is_map(&1) and is_binary(&1["type"]) and &1["type"] != "")) ->
        {:error,
         {:bad_request, ~s(each content block must carry a "type", e.g. {"type":"text","text":…})}}

      Enum.all?(content, &(&1["type"] == "image_url")) ->
        {:error, {:bad_request, "content must include at least one non-image_url content block"}}

      true ->
        with :ok <- validate_dynamic_ui_blocks(content),
             :ok <- validate_local_file_blocks(content) do
          {:ok, content}
        end
    end
  end

  def validate_content(_kind, _content),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc """
  Rejects an agent-authored Message whose text carries a whole-line inline Task
  marker (`{comma:task/<id>}` or `{comma:conversation/<id>}`).

  Clients render an inline Task chip only from a structured `conversation_ref`
  block, so a raw marker line is shown to the reader as unparsed placeholder
  text. The sender must reference the Task with a structured block instead:

      %{"type" => "conversation_ref", "conversation_id" => task_conversation_id,
        "kind" => "agent_task", "presentation" => "inline"}

  Enforced on append (`prepare/1`) only: persisted rows keep validating through
  `validate/1`, so historical Messages that already carry a marker stay readable.
  """
  @spec reject_agent_text_markers(map()) :: :ok | {:error, term()}
  def reject_agent_text_markers(attrs) when is_map(attrs) do
    if agent_text_marker_enforcement() == :reject and trim(attrs["actor_type"]) == "agent" do
      case agent_text_marker_lines(attrs["content"]) do
        [] ->
          :ok

        markers ->
          emit_agent_text_marker_rejected(markers)

          {:error,
           {:bad_request,
            "agent Message text must not carry a raw inline Task marker line " <>
              inspect(hd(markers)) <>
              "; send a structured conversation_ref block instead: " <>
              ~s({"type":"conversation_ref","conversation_id":"<task conversation>","kind":"agent_task","presentation":"inline"})}}
      end
    else
      :ok
    end
  end

  def reject_agent_text_markers(_attrs), do: :ok

  @doc """
  Enforcement for agent text carrying a raw inline Task marker line.

  `:reject` (default) fails the append with an actionable error; `:off` keeps
  accepting such text, so enforcement can be paused without shipping code.
  """
  @spec agent_text_marker_enforcement() :: :reject | :off
  def agent_text_marker_enforcement do
    case Application.get_env(:salix_im, @agent_text_marker_enforcement_key, :reject) do
      :off -> :off
      _other -> :reject
    end
  end

  def internal_delivery?(%{"actor_type" => "system"} = message) do
    not is_nil(message["agent_input"]) or
      (message["kind"] == "app_event" and
         get_in(message, ["metadata", "event_type"]) in [
           "provider.output",
           "provider.status",
           "provider.message",
           "message.redelivery"
         ])
  end

  def internal_delivery?(_message), do: false

  def visible_text(message) do
    if internal_delivery?(message), do: "", else: text_content(message["content"])
  end

  def text_content(content) when is_binary(content), do: content

  def text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
  end

  def text_content(_content), do: ""

  @doc false
  def local_file_refs(%{"content" => content}), do: local_file_refs(content)

  def local_file_refs(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "local_file", "local_file_ref" => ref} when is_binary(ref) -> [ref]
      _ -> []
    end)
  end

  def local_file_refs(_content), do: []

  defp validate_dynamic_ui_blocks(content) do
    blocks = Enum.filter(content, &match?(%{"type" => "dynamic_ui"}, &1))

    if length(blocks) <= 1 and
         Enum.all?(blocks, fn block ->
           block["version"] == 1 and is_binary(block["ui_ref"]) and
             byte_size(block["ui_ref"]) in 1..100 and is_binary(block["path"]) and
             String.starts_with?(block["path"], "/") and is_binary(block["summary"]) and
             String.length(block["summary"]) in 1..4000 and block["text"] == block["summary"] and
             not Map.has_key?(block, "html") and not Map.has_key?(block, "script") and
             (is_nil(block["origin_task_id"]) or
                SalixStore.Ids.valid_conversation_id?(block["origin_task_id"]))
         end) do
      :ok
    else
      {:error,
       {:bad_request,
        "Send one dynamic_ui attachment with version, ui_ref, path and matching summary/text"}}
    end
  end

  defp validate_local_file_blocks(content) do
    blocks = Enum.filter(content, &match?(%{"type" => "local_file"}, &1))
    refs = Enum.map(blocks, & &1["local_file_ref"])

    cond do
      length(blocks) > @max_local_file_refs ->
        {:error, {:bad_request, "content exceeds the local attachment limit"}}

      length(refs) != length(Enum.uniq(refs)) ->
        {:error, {:bad_request, "local attachment refs must be unique"}}

      not Enum.all?(blocks, &valid_local_file_block?/1) ->
        {:error, {:bad_request, "invalid ref-only local attachment"}}

      Enum.sum(Enum.map(blocks, &(&1["size"] || @max_local_file_bytes))) >
          @max_local_file_aggregate_bytes ->
        {:error, {:bad_request, "content exceeds the local attachment byte limit"}}

      true ->
        :ok
    end
  end

  defp valid_local_file_block?(%{"local_file_ref" => ref} = block) do
    keys = Map.keys(block) |> Enum.map(&to_string/1)

    is_binary(ref) and Regex.match?(@local_file_ref_pattern, ref) and
      Enum.all?(keys, &(&1 in @local_file_allowed_keys)) and
      valid_optional_display_name?(block["display_name"]) and
      valid_optional_size?(block["size"]) and
      valid_optional_media_type?(block["media_type"])
  end

  defp valid_local_file_block?(_block), do: false

  defp valid_optional_display_name?(nil), do: true

  defp valid_optional_display_name?(value),
    do:
      is_binary(value) and value != "" and byte_size(value) <= 255 and
        not String.contains?(value, ["/", "\\", <<0>>, "\r", "\n"])

  defp valid_optional_size?(nil), do: true

  defp valid_optional_size?(value),
    do: is_integer(value) and value >= 0 and value <= @max_local_file_bytes

  defp valid_optional_media_type?(nil), do: true

  defp valid_optional_media_type?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 255

  @spec reject_owner_identity(map()) :: :ok | {:error, term()}
  def reject_owner_identity(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "thread_root_message_id") or
          Map.has_key?(attrs, :thread_root_message_id) ->
        {:error, {:bad_request, "thread_root_message_id is assigned by the conversation owner"}}

      trim(attrs["message_id"]) != "" ->
        {:error, {:bad_request, "message_id is assigned by the conversation owner"}}

      true ->
        :ok
    end
  end

  @spec request_identity(map()) :: String.t() | nil
  def request_identity(attrs) when is_map(attrs) do
    cond do
      trim(attrs["idempotency_key"]) != "" ->
        "idempotency:" <> trim(attrs["idempotency_key"])

      trim(attrs["source_message_id"]) != "" ->
        "provider_message:" <> trim(attrs["source_message_id"])

      trim(attrs["client_request_id"]) != "" ->
        "client_request:" <> trim(attrs["client_request_id"])

      true ->
        nil
    end
  end

  @doc false
  def owner_inline_task_refs_v1_field, do: @owner_inline_task_refs_v1_field

  @doc false
  def owner_inline_task_refs_v1(message) when is_map(message) do
    case message[@owner_inline_task_refs_v1_field] do
      refs when is_list(refs) ->
        if valid_owner_inline_task_refs_v1?(refs), do: refs, else: []

      _missing_or_invalid ->
        []
    end
  end

  def owner_inline_task_refs_v1(_message), do: []

  @doc false
  def valid_owner_inline_task_refs_v1?(nil), do: true

  def valid_owner_inline_task_refs_v1?(refs) when is_list(refs) do
    length(refs) <= @inline_task_ref_limit and
      Enum.all?(refs, fn
        %{
          "type" => "conversation_ref",
          "conversation_id" => conversation_id,
          "kind" => "agent_task",
          "presentation" => "inline"
        } = ref ->
          map_size(ref) == 4 and Ids.valid_conversation_id?(conversation_id)

        _ref ->
          false
      end)
  end

  def valid_owner_inline_task_refs_v1?(_refs), do: false

  @spec request_fingerprint(map()) :: String.t()
  def request_fingerprint(%{"agent_input" => input, "source_message_id" => source} = message)
      when is_map(input) and is_binary(source) do
    # A verified provider source has first-write-wins input identity. Retry-time
    # prompt settings and context enrichment must not replace its accepted input.
    message
    |> Map.take(~w(kind actor_type source_message_id))
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  def request_fingerprint(message) when is_map(message) do
    message
    |> Map.take(
      ~w(kind participant_id actor_type user_id agent_id content metadata mentions delivery_filter reply_to_message_id platform_message)
    )
    |> :erlang.term_to_binary([:deterministic])
    |> Crypto.hex()
  end

  @spec participant_notification(String.t(), map(), map(), integer()) ::
          {:ok, map()} | {:error, term()}
  def participant_notification(message_id, attrs, metadata, created_at)
      when is_map(attrs) and is_map(metadata) and is_integer(created_at) do
    idempotency_key = trim(attrs["idempotency_key"])

    cond do
      not Ids.valid_message_id?(message_id) ->
        {:error, {:bad_request, "message_id must be canonical"}}

      idempotency_key == "" ->
        {:error, {:bad_request, "idempotency_key is required"}}

      true ->
        with {:ok, content} <- validate_content("message", attrs["content"]) do
          message =
            %{
              "message_id" => message_id,
              "request_identity" => request_identity(attrs),
              "idempotency_key" => idempotency_key,
              "actor_type" => "product",
              "role_label" => attrs["role_label"] || "product",
              "content" => content,
              "metadata" => metadata,
              "agent_id" => trim(attrs["source_agent_id"]),
              "created_at" => created_at
            }
            |> reject_empty()

          {:ok, Map.put(message, "request_fingerprint", request_fingerprint(message))}
        end
    end
  end

  @spec delivery_record(map(), map(), map(), integer()) :: map()
  def delivery_record(conversation, message, participant, recorded_at)
      when is_map(conversation) and is_map(message) and is_map(participant) do
    delivery = %{
      "delivery_kind" => "group_conversation",
      "status" => "pending",
      "agent_group_id" => conversation["agent_group_id"],
      "conversation_id" => conversation["conversation_id"],
      "conversation_kind" => conversation["kind"],
      "conversation_source_refs" => conversation["source_refs"] || %{},
      "conversation_title" => conversation["title"],
      "conversation_status" => conversation["status"],
      "conversation_message_tail_seq" =>
        conversation["message_tail_seq"] || conversation["message_count"],
      "conversation_updated_at" => conversation["updated_at"],
      "message_id" => message["message_id"],
      "reply_to_message_id" => message["reply_to_message_id"],
      "thread_root_message_id" => message["thread_root_message_id"],
      "message_seq" => message["seq"],
      "participant_id" => trim(participant["participant_id"]),
      "participant_role_label" => participant["role_label"],
      "participant_payload" =>
        if(is_map(participant["payload"]), do: participant["payload"], else: %{}),
      "source_participant_id" => message["participant_id"],
      "source_actor_type" => message["actor_type"],
      "source_user_id" => message["user_id"],
      "source_agent_id" => message["agent_id"],
      "source_role_label" => message["role_label"],
      "message_content" => message["content"],
      "message_metadata" => message["metadata"] || %{},
      "message_created_at" => message["created_at"],
      "attempts" => 0,
      "created_at" => recorded_at,
      "updated_at" => recorded_at
    }

    delivery =
      case owner_inline_task_refs_v1(message) do
        [] -> delivery
        refs -> Map.put(delivery, @owner_inline_task_refs_v1_field, refs)
      end

    case ProviderRecipientIdentity.from_owner_record(message) do
      nil -> delivery
      identity -> Map.put(delivery, ProviderRecipientIdentity.owner_field(), identity)
    end
  end

  @spec valid_sender?(map(), map()) :: boolean()
  def valid_sender?(participant, attrs) when is_map(participant) and is_map(attrs) do
    actor_type = attrs["actor_type"] || "user"

    Ids.valid_participant_id?(participant["participant_id"]) and
      case actor_type do
        "agent" ->
          participant["actor_type"] == "agent" and
            trim(participant["agent_id"]) == trim(attrs["agent_id"])

        provider_sender when provider_sender in ["provider_user", "provider_system"] ->
          provider = trim(attrs["provider"] || participant["provider"])

          participant["actor_type"] == "provider" and provider != "" and
            trim(participant["provider"]) == provider

        other ->
          participant["actor_type"] == other
      end
  end

  def valid_sender?(_participant, _attrs), do: false

  @spec normalize_delivery_filter(map(), map(), [String.t()]) ::
          {:ok, [String.t()], map()} | {:error, term()}
  def normalize_delivery_filter(attrs, memberships, default_target_ids)
      when is_map(attrs) and is_map(memberships) and is_list(default_target_ids) do
    if Map.has_key?(attrs, "delivery_filter") or Map.has_key?(attrs, :delivery_filter) do
      normalize_explicit_filter(attrs, memberships, default_target_ids)
    else
      {:ok, default_target_ids, attrs}
    end
  end

  @spec normalize_mentions(map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_mentions(attrs, memberships)
      when is_map(attrs) and is_map(memberships) do
    case attrs["mentions"] || attrs[:mentions] do
      nil ->
        {:ok, attrs}

      %{} = mentions ->
        participant_ids = mentions["participant_ids"] || mentions[:participant_ids]

        with true <- is_list(participant_ids),
             true <-
               length(participant_ids) <= @mention_limit and
                 Enum.all?(participant_ids, &is_binary/1),
             normalized <- participant_ids |> Enum.map(&trim/1) |> Enum.uniq() |> Enum.sort(),
             true <- length(normalized) == length(participant_ids),
             true <- Enum.all?(normalized, &Ids.valid_participant_id?/1),
             true <- Enum.all?(normalized, &Map.has_key?(memberships, &1)) do
          {:ok,
           attrs
           |> Map.delete(:mentions)
           |> Map.put("mentions", %{"participant_ids" => normalized})}
        else
          _ ->
            {:error,
             {:bad_request, "mentions.participant_ids must contain only conversation members"}}
        end

      _ ->
        {:error,
         {:bad_request, "mentions.participant_ids must contain only conversation members"}}
    end
  end

  @spec targets_participant?(map(), map()) :: boolean()
  def targets_participant?(participant, message)
      when is_map(participant) and is_map(message) do
    participant_id = trim(participant["participant_id"])
    sender_agent_id = trim(message["agent_id"])
    sender_participant_id = trim(message["participant_id"])

    participant_id != "" and addressed_to?(participant_id, message) and
      delivery_allowed?(participant, message) and
      case participant["actor_type"] do
        "agent" ->
          trim(participant["agent_id"]) != "" and participant["state"] != "inactive" and
            trim(participant["agent_id"]) != sender_agent_id

        "provider" ->
          trim(participant["provider"]) != "" and participant["state"] != "inactive" and
            participant_id != sender_participant_id

        _ ->
          false
      end
  end

  def targets_participant?(_participant, _message), do: false

  defp delivery_allowed?(participant, message) do
    %{"messages" => mode} = participant["notification_filter"]

    case mode do
      "all" -> true
      "mentioned" -> mentioned?(participant["participant_id"], message)
      "none" -> false
    end
  end

  defp mentioned?(
         participant_id,
         %{"mentions" => %{"participant_ids" => participant_ids}}
       )
       when is_binary(participant_id) and is_list(participant_ids),
       do: participant_id in participant_ids

  defp mentioned?(_participant_id, _message), do: false

  defp normalize_explicit_filter(attrs, memberships, default_target_ids) do
    filter = attrs["delivery_filter"] || attrs[:delivery_filter]

    with %{} <- filter,
         requested when is_list(requested) <-
           filter["participant_ids"] || filter[:participant_ids],
         true <-
           length(requested) <= @delivery_filter_limit and
             Enum.all?(requested, &is_binary/1),
         normalized <- requested |> Enum.map(&trim/1) |> Enum.uniq() |> Enum.sort(),
         true <- length(normalized) == length(requested),
         true <- Enum.all?(normalized, &Ids.valid_participant_id?/1),
         true <- Enum.all?(normalized, &Map.has_key?(memberships, &1)) do
      target_set = MapSet.new(default_target_ids)
      selected = Enum.filter(normalized, &MapSet.member?(target_set, &1))

      {:ok, selected,
       attrs
       |> Map.delete(:delivery_filter)
       |> Map.put("delivery_filter", %{"participant_ids" => selected})}
    else
      _ ->
        {:error,
         {:bad_request, "delivery_filter.participant_ids must contain only conversation members"}}
    end
  end

  defp addressed_to?(participant_id, message) do
    selected_by_filter? =
      case message["delivery_filter"] do
        %{"participant_ids" => participant_ids} when is_list(participant_ids) ->
          participant_id in participant_ids

        _ ->
          true
      end

    selected_by_mention? =
      case message["mentions"] do
        %{"participant_ids" => participant_ids} when is_list(participant_ids) ->
          participant_id in participant_ids

        _ ->
          true
      end

    selected_by_filter? and selected_by_mention?
  end

  defp valid_mentions_shape?(nil), do: true

  defp valid_mentions_shape?(mentions) when is_map(mentions) do
    ids = mentions["participant_ids"] || mentions[:participant_ids]

    is_list(ids) and length(ids) <= @mention_limit and
      Enum.all?(ids, &is_binary/1)
  end

  defp valid_mentions_shape?(_mentions), do: false

  # Whole-line markers only: text that merely mentions a marker, or any other
  # brace-delimited text, is left alone.
  defp agent_text_marker_lines(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&Regex.match?(@agent_text_marker_pattern, &1))

      _block ->
        []
    end)
  end

  defp agent_text_marker_lines(_content), do: []

  defp emit_agent_text_marker_rejected(markers) do
    :telemetry.execute(
      [:salix_im, :conversation_message, :agent_text_marker],
      %{count: length(markers)},
      %{
        component: "salix_im",
        operation: "agent_text_marker",
        outcome: "rejected",
        marker_kinds: markers |> Enum.map(&agent_text_marker_kind/1) |> Enum.uniq()
      }
    )

    Logger.warning(
      "salix_im rejected agent Message text with #{length(markers)} raw inline Task marker " <>
        "line(s); the sender must reference the Task with a structured conversation_ref block"
    )
  end

  defp agent_text_marker_kind(marker) do
    marker
    |> String.trim_leading("{comma:")
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp coerce_text_block(%{"text" => text} = block) when is_binary(text) do
    if is_nil(block["type"]), do: Map.put(block, "type", "text"), else: block
  end

  defp coerce_text_block(block), do: block

  defp reject_empty(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, "", %{}] end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
