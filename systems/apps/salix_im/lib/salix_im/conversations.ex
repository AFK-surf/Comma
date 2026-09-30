defmodule SalixIM.Conversations do
  @moduledoc """
  Bounded, read-only projections of durable conversation state.

  Reads never start an owner, repair an index, or mutate conversation storage.
  All production mutations enter through `SalixIM.ConversationServer`.
  """

  alias SalixIM.{
    ConversationGroupActor,
    ConversationMessage,
    ConversationMessageCodec,
    ConversationParticipantActivity,
    GroupDirectory
  }

  alias SalixIM.Ports.AgentDelivery
  alias SalixStore.{CasRecord, ConversationSearch, Crypto, Ids, Keys, S3, SearchDocumentEnvelope}

  @default_limit 200
  @max_limit 1_000
  @message_page_default_limit 100
  @message_page_max_limit 200
  @participant_limit SalixIM.ConversationLimits.participant_limit()
  @participant_page_limit SalixIM.ConversationLimits.participant_page_limit()
  @pin_limit 200
  @search_conversation_limit 200
  @search_message_limit 200
  @list_page_multiplier 4
  @list_scan_pages 2
  @list_scan_objects 2_000
  @conversation_list_read_concurrency 16
  @conversation_list_read_concurrency_cap 64
  @conversation_list_read_timeout 5_000
  @list_timestamp_max 9_999_999_999_999_999_999
  @list_timestamp_width 19
  @message_segment_scan_limit 32
  @task_search_segment_bytes 1_000_000
  @participant_status_read_concurrency 8
  @participant_status_read_timeout 2_500
  @internal_conversation_fields [
    "messages",
    "participants",
    "last_label_proposal_id",
    "task_public_output_message_id",
    "_participant_identity_slots",
    "log_start_seq",
    "_list_index_previous_updated_at"
  ]
  @spec list_group_conversations(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_group_conversations(group_id, opts \\ []) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, cursor} <- decode_conversation_cursor(opts[:cursor]),
         {:ok, limit} <- strict_limit(opts[:limit]),
         {:ok, kind} <- strict_conversation_kind(opts[:kind]),
         {:ok, records} <-
           list_conversation_records(
             group_id,
             conversation_list_start_after(group_id, cursor),
             limit + 1,
             kind
           ) do
      {data, rest} = Enum.split(records, limit)

      {:ok,
       %{"data" => Enum.map(data, &project_conversation/1), "has_more" => rest != []}
       |> put_optional(
         "next_cursor",
         if(rest != [], do: encode_conversation_cursor(List.last(data)))
       )}
    end
  end

  @spec get_group_conversation(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_group_conversation(group_id, conversation_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, conversation} <- get_group_conversation_record(group_id, conversation_id) do
      {:ok, project_conversation(conversation)}
    end
  end

  @doc false
  @spec get_group_conversation_record(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_group_conversation_record(group_id, conversation_id) do
    cond do
      not Ids.valid_group_id?(group_id) ->
        {:error, {:bad_request, "invalid group_id"}}

      not Ids.valid_conversation_id?(conversation_id) ->
        {:error, {:bad_request, "invalid conversation_id"}}

      true ->
        case read_json(Keys.ctl_group_conversation(group_id, conversation_id)) do
          {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) ->
            {:error, :not_found}

          other ->
            other
        end
    end
  end

  def get_group_conversation_with_messages(group_id, conversation_id, opts \\ []) do
    with {:ok, conversation} <- get_group_conversation_record(group_id, conversation_id),
         projected = project_conversation(conversation),
         {:ok, messages} <- list_messages(conversation, opts) do
      {:ok,
       %{
         "conversation" => projected,
         "messages" => messages
       }}
    end
  end

  def list_group_conversation_participants(group_id, conversation_id, opts \\ []) do
    with {:ok, _conversation} <- get_group_conversation_record(group_id, conversation_id),
         {:ok, page} <- participant_page(group_id, conversation_id, opts) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => page.data
       }
       |> put_optional("has_more", page.has_more)
       |> put_optional("next_cursor", page.next_cursor)}
    end
  end

  def get_group_conversation_participant(group_id, conversation_id, participant_id) do
    with {:ok, _conversation} <- get_group_conversation_record(group_id, conversation_id),
         :ok <- require_id(participant_id, "participant_id", &Ids.valid_participant_id?/1),
         {:ok,
          %{
            "conversation_id" => ^conversation_id,
            "participant_id" => ^participant_id
          } = participant} <-
           get_participant(group_id, conversation_id, participant_id) do
      {:ok, participant}
    else
      {:ok, _mismatched} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def search_group_conversations(group_id, query, opts \\ []) do
    with {:ok, q} <- search_query(query),
         {:ok, page} <-
           list_group_conversations(group_id, limit: @search_conversation_limit),
         {:ok, hits} <- search_records(page["data"], q) do
      {:ok, hits |> Enum.sort_by(&search_sort_key/1, :desc) |> Enum.take(search_limit(opts))}
    end
  end

  @doc """
  Searches one bounded Conversation window using natural-language keyword
  overlap. Unlike `search_group_conversations/3`, the query does not need to
  appear as one contiguous phrase. At most one best hit is returned per
  Conversation.
  """
  def search_group_conversations_by_keywords(group_id, query, opts \\ []) do
    with {:ok, normalized_query} <- search_query(query),
         {:ok, terms} <- keyword_terms(normalized_query),
         {:ok, page} <-
           list_group_conversations(group_id, limit: @search_conversation_limit),
         {:ok, hits} <- search_records_by_keywords(page["data"], normalized_query, terms) do
      {:ok, hits |> Enum.sort_by(&search_sort_key/1, :desc) |> Enum.take(search_limit(opts))}
    end
  end

  @doc "Bounded Task-only search DTO used by the Comma public facade."
  def search_group_tasks(group_id, query, opts \\ []) do
    with {:ok, q} <- task_search_query(query),
         {:ok, search_opts} <- task_search_options(opts) do
      search_projection(group_id, q, search_opts)
    end
  end

  defp search_projection(group_id, query, search_opts) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, hits} <- ConversationSearch.search(group_id, query, search_opts) do
      {:ok, hits}
    else
      {:error, :invalid} -> {:error, {:bad_request, "invalid search parameters"}}
      {:error, :unavailable} -> {:error, :conversation_search_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def list_group_conversation_messages(group_id, conversation_id, opts \\ []) do
    with {:ok, conversation} <- get_group_conversation_record(group_id, conversation_id) do
      list_messages(conversation, opts)
    end
  end

  @doc """
  One bounded, `seq`-contiguous page of Messages, positioned by a `seq` of
  this Conversation.

  At most one of `before`, `after`, or `around` selects the position; without
  one the page ends at the tail. `before` ends the page just before that
  `seq`, `after` starts it just after, and `around`
  centers it on that `seq` and fills toward the other end at the head or tail.
  A position must be a `seq` in `message_head_seq..message_tail_seq` of this
  Conversation, or the read fails with `{:error, :not_found}`. `limit` is the
  page size: default #{@message_page_default_limit}, clamped to
  #{@message_page_max_limit}.

  The page reports:

  - `covered`: the `seq` span it read, `nil` when it read none. Each `seq` in
    the span is in `messages`; a reader that hides a Message still knows that
    `seq` is read.
  - `has_older` and `has_newer`: whether the Conversation has Messages outside
    the span, at read time.
  - `bounds`: the Conversation head and tail `seq` from the same record read,
    `nil` when the Conversation has no Messages.
  """
  @spec list_group_conversation_message_page(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_group_conversation_message_page(group_id, conversation_id, opts \\ []) do
    with {:ok, conversation} <- get_group_conversation_record(group_id, conversation_id),
         {:ok, position} <- message_page_position(opts),
         {:ok, limit} <- message_page_limit(opts[:limit]),
         {:ok, {first_seq, last_seq}} <- message_page_range(conversation, position, limit),
         {:ok, messages} <-
           collect_messages(conversation, first_seq, max(last_seq - first_seq + 1, 0)) do
      head_seq = conversation_head_seq(conversation)
      tail_seq = conversation_tail_seq(conversation)

      {:ok,
       %{
         "messages" => messages,
         "covered" => covered_span(messages),
         "has_older" => tail_seq > 0 and min(first_seq, last_seq + 1) > head_seq,
         "has_newer" => tail_seq > 0 and max(last_seq, first_seq - 1) < tail_seq,
         "bounds" =>
           if(tail_seq > 0, do: %{"head_seq" => head_seq, "tail_seq" => tail_seq}, else: nil)
       }}
    end
  end

  defp covered_span([]), do: nil

  defp covered_span([first | _] = messages),
    do: %{"first_seq" => first["seq"], "last_seq" => List.last(messages)["seq"]}

  defp message_page_position(opts) do
    positions =
      [before: opts[:before], after: opts[:after], around: opts[:around]]
      # A nested query parameter arrives as a map or list; it is present, and
      # the parse below rejects it.
      |> Enum.reject(fn {_key, value} ->
        is_nil(value) or (is_binary(value) and String.trim(value) == "")
      end)

    case positions do
      [] ->
        {:ok, :tail}

      [{key, value}] ->
        case parse_positive_integer(value) do
          {:ok, seq} -> {:ok, {key, seq}}
          :error -> {:error, {:bad_request, "#{key} must be a positive integer"}}
        end

      _many ->
        {:error, {:bad_request, "at most one of before, after, around is allowed"}}
    end
  end

  defp message_page_limit(value) when value in [nil, ""], do: {:ok, @message_page_default_limit}

  defp message_page_limit(value) do
    case parse_positive_integer(value) do
      {:ok, limit} -> {:ok, min(limit, @message_page_max_limit)}
      :error -> {:error, {:bad_request, "limit must be a positive integer"}}
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error

  # The page is an inclusive seq range inside the Conversation head and tail.
  # An empty range has `last_seq = first_seq - 1`. The position is checked
  # against this Conversation's own head and tail, so a seq from another
  # Conversation cannot address a Message outside this one.
  defp message_page_range(conversation, position, limit) do
    head_seq = conversation_head_seq(conversation)
    tail_seq = conversation_tail_seq(conversation)

    case position do
      :tail when tail_seq == 0 ->
        {:ok, {1, 0}}

      :tail ->
        {:ok, {max(tail_seq - limit + 1, head_seq), tail_seq}}

      {_kind, seq} when tail_seq == 0 or seq < head_seq or seq > tail_seq ->
        {:error, :not_found}

      {:before, seq} ->
        {:ok, {max(seq - limit, head_seq), seq - 1}}

      {:after, seq} ->
        {:ok, {seq + 1, min(seq + limit, tail_seq)}}

      {:around, seq} ->
        first_seq = seq - div(limit - 1, 2)
        first_seq = first_seq |> min(tail_seq - limit + 1) |> max(head_seq)
        {:ok, {first_seq, min(first_seq + limit - 1, tail_seq)}}
    end
  end

  def group_conversation_message_exists?(group_id, conversation_id, message_id) do
    match?({:ok, _message}, get_group_conversation_message(group_id, conversation_id, message_id))
  end

  def get_group_conversation_message(group_id, conversation_id, message_id) do
    with {:ok, _conversation} <- get_group_conversation_record(group_id, conversation_id),
         :ok <- require_id(message_id, "message_id", &Ids.valid_message_id?/1),
         {:ok, pointer} <- message_pointer_by_id(group_id, conversation_id, message_id),
         {:ok, message} <-
           message_from_pointer(group_id, conversation_id, pointer, message_id: message_id) do
      {:ok, message}
    end
  end

  @doc false
  @spec task_search_content_window(map()) :: {:ok, map()} | {:error, term()}
  def task_search_content_window(
        %{
          "kind" => "agent_task",
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id
        } = conversation
      ) do
    tail_seq = conversation_tail_seq(conversation)
    head_seq = conversation_head_seq(conversation)

    if tail_seq == 0 do
      with {:ok, window} <- SearchDocumentEnvelope.message_window([], head_seq, tail_seq) do
        {:ok, Map.merge(window, %{source_bytes: 0, segment_count: 0})}
      end
    else
      start_seq = SearchDocumentEnvelope.message_window_start(head_seq, tail_seq)

      with {:ok, %{"segment_id" => segment_id}} <-
             message_pointer_by_seq(group_id, conversation_id, start_seq) do
        collect_task_search_segments(
          group_id,
          conversation_id,
          segment_id,
          start_seq,
          tail_seq,
          head_seq,
          [],
          0,
          0,
          SearchDocumentEnvelope.message_slots()
        )
      else
        {:error, :not_found} -> {:error, :message_sequence_index_missing}
        {:error, _reason} = error -> error
      end
    end
  end

  def task_search_content_window(_conversation), do: {:error, :not_agent_task}

  def group_conversation_delivery_status(group_id, conversation_id, opts \\ []) do
    with {:ok, conversation} <- get_group_conversation_record(group_id, conversation_id),
         :ok <-
           validate_optional_id(
             opts[:participant_id],
             "participant_id",
             &Ids.valid_participant_id?/1
           ),
         :ok <- validate_optional_id(opts[:message_id], "message_id", &Ids.valid_message_id?/1),
         {:ok, limit} <- strict_limit(opts[:limit]),
         participant_id <- trim(opts[:participant_id]),
         message_id <- trim(opts[:message_id]),
         {:ok, participant} <-
           delivery_status_participant(conversation, participant_id),
         {:ok, records} <-
           delivery_records(group_id, conversation_id, participant_id, message_id, limit) do
      deliveries =
        records
        |> Enum.filter(&delivery_matches?(&1, participant_id, message_id))
        |> Enum.sort_by(
          &{&1["updated_at"] || &1["created_at"] || 0, &1["message_id"] || ""},
          :desc
        )
        |> Enum.take(limit)
        |> Enum.map(&project_delivery(retire_old_pending_delivery(&1, conversation)))

      {:ok,
       %{
         "agent_group_id" => group_id,
         "conversation_id" => conversation_id,
         "participant_id" => participant_id,
         "message_id" => message_id,
         "participant" => project_participant_diagnostic(participant),
         "source_progress" => participant_source_progress(participant),
         "deliveries" => deliveries,
         "limit" => limit
       }
       |> strip_empty()}
    end
  end

  def list_conversation_pins(group_id, tenant_id, opts \\ []) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id),
         {:ok, limit} <- pin_limit(opts[:limit]),
         {:ok, cursor} <- decode_pin_cursor(opts[:cursor], group_id),
         {:ok, pins} <- read_live_pins(group_id) do
      pins =
        pins
        |> Enum.sort_by(&pin_sort_key/1, :desc)
        |> after_pin_cursor(cursor)

      {selected, rest} = Enum.split(pins, limit)

      {:ok,
       %{"data" => selected, "has_more" => rest != []}
       |> put_optional(
         "next_cursor",
         if(rest != [], do: encode_pin_cursor(group_id, List.last(selected)))
       )}
    end
  end

  @doc """
  Read activity for an already-bounded participant snapshot.

  Slow or unavailable activity projections are omitted; participant storage
  itself has already been read by the caller and is not reinterpreted here.
  """
  def group_conversation_participant_statuses(group_id, conversation_id, participants)
      when is_list(participants) do
    cond do
      not (Ids.valid_group_id?(group_id) and Ids.valid_conversation_id?(conversation_id)) ->
        {:error, {:bad_request, "invalid conversation_id"}}

      length(participants) > @participant_limit ->
        {:error,
         {:bad_request, "participants must contain at most #{@participant_limit} entries"}}

      true ->
        statuses =
          participants
          |> Enum.filter(&valid_participant?/1)
          |> Task.async_stream(
            fn participant ->
              id = participant["participant_id"]

              {id,
               ConversationParticipantActivity.read(
                 group_id,
                 conversation_id,
                 id,
                 participant
               )}
            end,
            ordered: false,
            max_concurrency: @participant_status_read_concurrency,
            timeout: @participant_status_read_timeout,
            on_timeout: :kill_task
          )
          |> Enum.reduce(%{}, fn
            {:ok, {id, {:ok, status}}}, acc -> Map.put(acc, id, status)
            _unavailable, acc -> acc
          end)

        {:ok, statuses}
    end
  end

  defp read_live_pins(group_id) do
    with {:ok, pins} <- read_pin_aggregate(group_id) do
      Enum.reduce_while(pins, {:ok, []}, fn pin, {:ok, acc} ->
        case get_group_conversation(group_id, pin["conversation_id"]) do
          {:ok, _conversation} ->
            {:cont, {:ok, [pin_json(pin) | acc]}}

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, live} -> {:ok, Enum.reverse(live)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Read the stored per-bucket Task order for a Group.

  The order is a client-authored arrangement: buckets are opaque client
  vocabulary and ids may reference Tasks that have since moved on — readers
  layer the order over the live list rather than treating it as membership.
  """
  def get_task_order(group_id, tenant_id) do
    with {:ok, _group} <- GroupDirectory.get_group(group_id, tenant_id) do
      case CasRecord.get(
             Keys.ctl_task_order_aggregate(group_id),
             :invalid_task_order_aggregate
           ) do
        {:ok, aggregate} ->
          case ConversationGroupActor.validate_task_order_aggregate(aggregate, group_id) do
            :ok -> {:ok, %{"orders" => aggregate["orders"]}}
            {:error, _reason} = error -> error
          end

        {:error, :not_found} ->
          {:ok, %{"orders" => %{}}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp read_pin_aggregate(group_id) do
    case CasRecord.get(Keys.ctl_conversation_pins_aggregate(group_id), :invalid_pin_aggregate) do
      {:ok, %{"agent_group_id" => ^group_id, "pins" => pins}} when is_list(pins) ->
        if length(pins) <= @pin_limit and Enum.all?(pins, &valid_pin?(&1, group_id)),
          do: {:ok, pins},
          else: {:error, :invalid_pin_aggregate}

      {:ok, _invalid} ->
        {:error, :invalid_pin_aggregate}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp valid_pin?(pin, group_id) do
    is_map(pin) and pin["agent_group_id"] == group_id and
      Ids.valid_conversation_id?(pin["conversation_id"]) and is_integer(pin["pinned_at"]) and
      is_integer(pin["created_at"]) and is_integer(pin["updated_at"])
  end

  defp pin_json(pin),
    do: Map.take(pin, ~w(agent_group_id conversation_id pinned_at created_at updated_at))

  defp pin_limit(value) when value in [nil, ""], do: {:ok, @pin_limit}
  defp pin_limit(value) when is_integer(value) and value in 1..@pin_limit, do: {:ok, value}

  defp pin_limit(value) when is_integer(value),
    do: {:error, {:bad_request, "limit must be <= #{@pin_limit}"}}

  defp pin_limit(_value), do: {:error, {:bad_request, "limit must be a positive integer"}}

  defp decode_pin_cursor(value, _group_id) when value in [nil, ""], do: {:ok, nil}

  defp decode_pin_cursor(cursor, group_id) do
    with {:ok, json} <- Base.url_decode64(to_string(cursor), padding: false),
         {:ok,
          %{
            "agent_group_id" => ^group_id,
            "pinned_at" => pinned_at,
            "conversation_id" => conversation_id
          }}
         when is_integer(pinned_at) and is_binary(conversation_id) <- Jason.decode(json) do
      {:ok, {pinned_at, conversation_id}}
    else
      _ -> {:error, {:bad_request, "invalid cursor"}}
    end
  end

  defp encode_pin_cursor(group_id, pin) do
    %{
      "agent_group_id" => group_id,
      "pinned_at" => pin["pinned_at"],
      "conversation_id" => pin["conversation_id"]
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp after_pin_cursor(pins, nil), do: pins
  defp after_pin_cursor(pins, cursor), do: Enum.filter(pins, &(pin_sort_key(&1) < cursor))
  defp pin_sort_key(pin), do: {pin["pinned_at"], pin["conversation_id"]}

  # Bounded conversation list projection.

  defp list_conversation_records(group_id, start_after, desired_count, nil) do
    started_at = System.monotonic_time()
    page_size = min(max(desired_count * @list_page_multiplier, 100), @max_limit)

    opts =
      [max_keys: page_size]
      |> maybe_put(:start_after, start_after)

    result =
      collect_conversation_records(
        group_id,
        opts,
        desired_count,
        [],
        @list_scan_pages,
        @list_scan_objects
      )

    emit_conversation_list_read(result, desired_count - 1, started_at)
    result
  end

  defp list_conversation_records(group_id, start_after, desired_count, kind) do
    started_at = System.monotonic_time()
    page_size = min(max(desired_count * @list_page_multiplier, 100), @max_limit)

    opts =
      [max_keys: page_size]
      |> maybe_put(:start_after, start_after)

    result =
      collect_filtered_conversation_records(
        group_id,
        opts,
        kind,
        desired_count,
        [],
        @list_scan_pages,
        @list_scan_objects
      )

    emit_conversation_list_read(result, desired_count - 1, started_at)
    result
  end

  defp collect_filtered_conversation_records(
         group_id,
         opts,
         kind,
         desired_count,
         acc,
         pages_remaining,
         objects_remaining
       ) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_group_conversation_list_prefix(group_id), opts),
         true <- length(objects) <= objects_remaining,
         {:ok, hydrated} <- hydrate_conversation_indexes(group_id, objects, length(objects)) do
      matches = Enum.filter(hydrated, &(&1["kind"] == kind))
      acc = acc ++ matches
      remaining = objects_remaining - length(objects)
      continuation? = is_binary(next) and next != ""

      cond do
        length(acc) >= desired_count ->
          {:ok, Enum.take(acc, desired_count)}

        not continuation? ->
          {:ok, acc}

        pages_remaining <= 1 or remaining <= 0 ->
          {:error, :conversation_list_scan_limit_exceeded}

        true ->
          next_opts =
            opts
            |> Keyword.put(:continuation_token, next)
            |> Keyword.delete(:start_after)
            |> Keyword.update!(:max_keys, &min(&1, remaining))

          collect_filtered_conversation_records(
            group_id,
            next_opts,
            kind,
            desired_count,
            acc,
            pages_remaining - 1,
            remaining
          )
      end
    else
      false -> {:error, :conversation_list_scan_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  defp collect_conversation_records(
         group_id,
         opts,
         desired_count,
         acc,
         pages_remaining,
         objects_remaining
       ) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_group_conversation_list_prefix(group_id), opts),
         true <- length(objects) <= objects_remaining,
         {:ok, hydrated} <-
           hydrate_conversation_indexes(group_id, objects, desired_count - length(acc)) do
      acc = acc ++ hydrated
      remaining = objects_remaining - length(objects)
      continuation? = is_binary(next) and next != ""

      cond do
        length(acc) >= desired_count ->
          {:ok, Enum.take(acc, desired_count)}

        not continuation? ->
          {:ok, acc}

        pages_remaining <= 1 or remaining <= 0 ->
          {:error, :conversation_list_scan_limit_exceeded}

        true ->
          next_opts =
            opts
            |> Keyword.put(:continuation_token, next)
            |> Keyword.delete(:start_after)
            |> Keyword.update!(:max_keys, &min(&1, remaining))

          collect_conversation_records(
            group_id,
            next_opts,
            desired_count,
            acc,
            pages_remaining - 1,
            remaining
          )
      end
    else
      false -> {:error, :conversation_list_scan_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  defp hydrate_conversation_indexes(_group_id, [], _desired_count), do: {:ok, []}

  defp hydrate_conversation_indexes(group_id, objects, desired_count) do
    started_at = System.monotonic_time()

    result =
      hydrate_conversation_index_batches(group_id, objects, desired_count, [], 0)

    {records, object_count} =
      case result do
        {:ok, records, object_count} -> {records, object_count}
        {:error, _reason, object_count} -> {[], object_count}
      end

    :telemetry.execute(
      [:salix_im, :conversations, :list_hydration],
      %{
        duration: System.monotonic_time() - started_at,
        object_count: object_count,
        hydrated_count: length(records),
        dropped_count: object_count - length(records)
      },
      %{
        concurrency: conversation_list_read_concurrency(),
        status: if(match?({:ok, _records, _object_count}, result), do: :ok, else: :error)
      }
    )

    case result do
      {:ok, _records, _object_count} -> {:ok, records}
      {:error, reason, _object_count} -> {:error, reason}
    end
  end

  defp hydrate_conversation_index_batches(
         _group_id,
         _objects,
         desired_count,
         records,
         object_count
       )
       when desired_count <= 0,
       do: {:ok, records, object_count}

  defp hydrate_conversation_index_batches(
         _group_id,
         [],
         _desired_count,
         records,
         object_count
       ),
       do: {:ok, records, object_count}

  defp hydrate_conversation_index_batches(
         group_id,
         objects,
         desired_count,
         records,
         object_count
       ) do
    # The raw page overfetches to tolerate stale indexes. Hydrate the exact
    # initial window, then use a concurrency-sized recovery batch only after
    # that window proves to contain stale indexes.
    batch_size =
      if object_count == 0,
        do: desired_count,
        else: max(desired_count, conversation_list_read_concurrency())

    {batch, rest} = Enum.split(objects, batch_size)

    case hydrate_conversation_index_batch(group_id, batch) do
      {:ok, hydrated} ->
        hydrate_conversation_index_batches(
          group_id,
          rest,
          desired_count - length(hydrated),
          records ++ hydrated,
          object_count + length(batch)
        )

      {:error, reason} ->
        {:error, reason, object_count + length(batch)}
    end
  end

  defp hydrate_conversation_index_batch(group_id, objects) do
    objects
    |> Task.async_stream(
      &conversation_from_list_index(group_id, &1),
      ordered: true,
      max_concurrency: conversation_list_read_concurrency(),
      timeout: conversation_list_read_timeout(),
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, conversation}}, {:ok, records} ->
        {:cont, {:ok, [conversation | records]}}

      {:ok, :stale}, {:ok, records} ->
        {:cont, {:ok, records}}

      {:ok, {:error, reason}}, {:ok, _records} ->
        {:halt, {:error, {:conversation_list_hydration_failed, reason}}}

      {:exit, reason}, {:ok, _records} ->
        {:halt, {:error, {:conversation_list_hydration_failed, reason}}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp conversation_from_list_index(group_id, object) do
    case read_json(object.key) do
      {:ok, %{"conversation_id" => conversation_id}} ->
        case get_group_conversation_record(group_id, conversation_id) do
          {:ok, conversation} ->
            if conversation_index_key(group_id, conversation) == object.key,
              do: {:ok, conversation},
              else: :stale

          {:error, :not_found} ->
            :stale

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _invalid} ->
        :stale

      {:error, :not_found} ->
        :stale

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conversation_list_read_concurrency do
    :salix_im
    |> Application.get_env(
      :conversation_list_read_concurrency,
      @conversation_list_read_concurrency
    )
    |> normalize_positive_integer(@conversation_list_read_concurrency)
    |> min(@conversation_list_read_concurrency_cap)
  end

  defp conversation_list_read_timeout do
    :salix_im
    |> Application.get_env(:conversation_list_read_timeout, @conversation_list_read_timeout)
    |> normalize_positive_integer(@conversation_list_read_timeout)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default

  defp emit_conversation_list_read(result, limit, started_at) do
    hydrated_count = if match?({:ok, _}, result), do: result |> elem(1) |> length(), else: 0

    :telemetry.execute(
      [:salix_im, :conversations, :list_page],
      %{
        duration: System.monotonic_time() - started_at,
        hydrated_count: hydrated_count
      },
      %{
        limit: limit,
        concurrency: conversation_list_read_concurrency(),
        status: if(match?({:ok, _records}, result), do: :ok, else: :error)
      }
    )
  end

  defp conversation_index_key(group_id, conversation) do
    Keys.ctl_group_conversation_list_entry(
      group_id,
      reverse_timestamp(SalixIM.TaskArchive.list_timestamp(conversation)),
      conversation["conversation_id"] || ""
    )
  end

  defp reverse_timestamp(value) do
    timestamp =
      case Integer.parse(to_string(value)) do
        {number, ""} when number >= 0 -> min(number, @list_timestamp_max)
        _ -> 0
      end

    (@list_timestamp_max - timestamp)
    |> Integer.to_string()
    |> String.pad_leading(@list_timestamp_width, "0")
  end

  # Participant reads.

  defp participant_page(group_id, conversation_id, opts) do
    limit = clamp_limit(opts[:limit], @participant_page_limit, @participant_page_limit)

    with {:ok, cursor} <- decode_participant_cursor(opts[:cursor]),
         prefix <-
           Keys.ctl_group_conversation_participant_states_prefix(group_id, conversation_id),
         {:ok, %{objects: objects}} <-
           S3.list(prefix,
             max_keys: limit + 1,
             start_after: if(cursor == "", do: nil, else: cursor)
           ),
         {selected, rest} <- Enum.split(objects, limit),
         {:ok, participants} <- hydrate_participants(selected) do
      {:ok,
       %{
         data: participants,
         has_more: rest != [],
         next_cursor:
           if(rest != [], do: selected |> List.last() |> then(&encode_participant_cursor(&1.key)))
       }}
    end
  end

  defp hydrate_participants(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, participants} ->
      case read_json(object.key) do
        {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) ->
          {:cont, {:ok, participants}}

        {:ok, %{"participant_id" => _participant_id} = participant} ->
          {:cont, {:ok, [participant | participants]}}

        {:ok, _invalid} ->
          {:halt, {:error, {:participant_read_failed, object.key, :invalid_participant_state}}}

        {:error, reason} ->
          {:halt, {:error, {:participant_read_failed, object.key, reason}}}
      end
    end)
    |> case do
      {:ok, participants} ->
        {:ok, Enum.reverse(participants)}

      {:error, _reason} = error ->
        error
    end
  end

  defp get_participant(group_id, conversation_id, participant_id) do
    group_id
    |> Keys.ctl_group_conversation_participant_state(conversation_id, participant_id)
    |> read_json()
    |> case do
      {:ok, %{"deleted_at" => deleted_at}} when not is_nil(deleted_at) -> {:error, :not_found}
      other -> other
    end
  end

  # Message reads.

  defp list_messages(conversation, opts) do
    with :ok <- validate_optional_id(opts[:after_id], "after_id", &Ids.valid_message_id?/1),
         :ok <- validate_optional_id(opts[:through_id], "through_id", &Ids.valid_message_id?/1),
         :ok <- validate_optional_seq(opts[:after_seq]),
         {:ok, limit} <- strict_limit(opts[:limit]),
         {:ok, tail} <- optional_limit(opts[:tail]) do
      group_id = conversation["agent_group_id"]
      conversation_id = conversation["conversation_id"]

      cond do
        trim(opts[:through_id]) != "" ->
          message_id = opts[:through_id]

          with {:ok, pointer} <- message_pointer_by_id(group_id, conversation_id, message_id),
               {:ok, _target} <-
                 message_from_pointer(group_id, conversation_id, pointer, message_id: message_id) do
            start_seq = max(pointer["seq"] - limit + 1, conversation_head_seq(conversation))
            collect_messages(conversation, start_seq, pointer["seq"] - start_seq + 1)
          end

        is_integer(tail) ->
          tail_seq = conversation_tail_seq(conversation)

          collect_messages(
            conversation,
            max(tail_seq - tail + 1, conversation_head_seq(conversation)),
            tail
          )

        is_integer(opts[:after_seq]) ->
          collect_messages(
            conversation,
            max(opts[:after_seq] + 1, conversation_head_seq(conversation)),
            limit
          )

        trim(opts[:after_id]) != "" ->
          after_id = trim(opts[:after_id])

          with {:ok, pointer} <- message_pointer_by_id(group_id, conversation_id, after_id),
               {:ok, _target} <-
                 message_from_pointer(
                   group_id,
                   conversation_id,
                   pointer,
                   message_id: after_id
                 ) do
            collect_messages(conversation, pointer["seq"] + 1, limit)
          else
            {:error, :not_found} -> {:ok, []}
            {:error, _reason} = error -> error
          end

        true ->
          collect_messages(conversation, conversation_head_seq(conversation), limit)
      end
    end
  end

  defp collect_messages(_conversation, _start_seq, 0), do: {:ok, []}

  defp collect_messages(conversation, start_seq, limit) do
    group_id = conversation["agent_group_id"]
    conversation_id = conversation["conversation_id"]
    tail_seq = conversation_tail_seq(conversation)

    cond do
      tail_seq == 0 or start_seq > tail_seq ->
        {:ok, []}

      start_seq <= 0 ->
        {:error, :invalid_message_sequence}

      true ->
        collect_messages_from_index(
          group_id,
          conversation_id,
          start_seq,
          tail_seq,
          limit
        )
    end
  end

  defp collect_messages_from_index(group_id, conversation_id, start_seq, tail_seq, limit) do
    case message_pointer_by_seq(group_id, conversation_id, start_seq) do
      {:ok, %{"segment_id" => segment_id}} ->
        collect_message_segments(
          group_id,
          conversation_id,
          segment_id,
          start_seq,
          tail_seq,
          limit,
          [],
          @message_segment_scan_limit
        )

      {:error, :not_found} ->
        {:error, :message_sequence_index_missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp collect_task_search_segments(
         _group_id,
         _conversation_id,
         _segment_id,
         _next_seq,
         _tail_seq,
         _head_seq,
         _projected,
         _source_bytes,
         _segment_count,
         0
       ),
       do: {:error, :task_search_segment_limit_exceeded}

  defp collect_task_search_segments(
         group_id,
         conversation_id,
         segment_id,
         next_seq,
         tail_seq,
         head_seq,
         projected,
         source_bytes,
         segment_count,
         segments_remaining
       ) do
    key = Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    with {:ok, {rows, body}} <- read_task_search_segment(key),
         {:ok, segment_index} <-
           required_message_segment_index(group_id, conversation_id, segment_id),
         {:ok, selected} <- select_task_search_rows(rows, next_seq, tail_seq),
         {:ok, slots} <- project_task_search_slots(selected) do
      projected =
        slots
        |> Enum.reverse(projected)

      last_seq = selected |> List.last() |> Map.fetch!("seq")
      source_bytes = source_bytes + byte_size(body)
      segment_count = segment_count + 1

      cond do
        last_seq >= tail_seq ->
          finish_task_search_window(
            projected,
            head_seq,
            tail_seq,
            source_bytes,
            segment_count
          )

        is_binary(segment_index["next_segment_id"]) and
            segment_index["next_segment_id"] != "" ->
          collect_task_search_segments(
            group_id,
            conversation_id,
            segment_index["next_segment_id"],
            last_seq + 1,
            tail_seq,
            head_seq,
            projected,
            source_bytes,
            segment_count,
            segments_remaining - 1
          )

        true ->
          {:error, :message_segment_index_missing}
      end
    end
  end

  defp read_task_search_segment(key) do
    case S3.get(key, range: {0, @task_search_segment_bytes + 1}) do
      {:ok, %{body: body}} when byte_size(body) <= @task_search_segment_bytes ->
        with {:ok, rows} <- ConversationMessageCodec.decode_segment(body),
             do: {:ok, {rows, body}}

      {:ok, %{body: _oversized}} ->
        {:error, :task_search_segment_too_large}

      {:error, _reason} = error ->
        error
    end
  end

  defp select_task_search_rows(rows, next_seq, tail_seq) do
    selected =
      rows
      |> Enum.filter(&(&1["seq"] >= next_seq and &1["seq"] <= tail_seq))
      |> Enum.sort_by(& &1["seq"])

    expected = Enum.to_list(next_seq..min(tail_seq, next_seq + length(selected) - 1))

    cond do
      selected == [] ->
        {:error, :message_sequence_gap}

      ConversationMessageCodec.validate_rows(selected) != :ok ->
        {:error, :invalid_message_segment}

      Enum.map(selected, & &1["seq"]) != expected ->
        {:error, :message_sequence_gap}

      true ->
        {:ok, selected}
    end
  end

  defp project_task_search_slots(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      result =
        SearchDocumentEnvelope.message_slot(%{
          id: message["message_id"],
          seq: message["seq"],
          created_at: message["created_at"],
          content: ConversationMessage.visible_text(message)
        })

      case result do
        {:ok, slot} -> {:cont, {:ok, [slot | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_task_search_message}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp finish_task_search_window(
         newest_first_slots,
         head_seq,
         tail_seq,
         source_bytes,
         segment_count
       ) do
    with {:ok, window} <-
           SearchDocumentEnvelope.message_window(
             Enum.reverse(newest_first_slots),
             head_seq,
             tail_seq
           ) do
      {:ok,
       Map.merge(window, %{
         source_bytes: source_bytes,
         segment_count: segment_count
       })}
    end
  end

  defp collect_message_segments(
         _group_id,
         _conversation_id,
         _segment_id,
         _start_seq,
         _tail_seq,
         _limit,
         _acc,
         0
       ),
       do: {:error, :message_segment_scan_limit_exceeded}

  defp collect_message_segments(
         group_id,
         conversation_id,
         segment_id,
         start_seq,
         tail_seq,
         limit,
         acc,
         pages_remaining
       ) do
    with {:ok, {rows, segment_index}} <-
           read_indexed_message_segment(group_id, conversation_id, segment_id),
         {:ok, acc} <- merge_message_rows(acc, rows, start_seq, tail_seq) do
      last_seq = acc |> List.last() |> then(&if(&1, do: &1["seq"], else: start_seq - 1))

      cond do
        length(acc) >= limit ->
          {:ok, Enum.take(acc, limit)}

        last_seq >= tail_seq ->
          {:ok, acc}

        is_binary(segment_index["next_segment_id"]) and
            segment_index["next_segment_id"] != "" ->
          collect_message_segments(
            group_id,
            conversation_id,
            segment_index["next_segment_id"],
            start_seq,
            tail_seq,
            limit,
            acc,
            pages_remaining - 1
          )

        true ->
          {:error, :message_segment_index_missing}
      end
    end
  end

  defp message_pointer_by_id(group_id, conversation_id, message_id) do
    group_id
    |> Keys.ctl_group_conversation_message_identity(conversation_id, Crypto.hex(message_id))
    |> read_message_pointer(message_id: message_id)
  end

  defp message_pointer_by_seq(group_id, conversation_id, seq) do
    group_id
    |> Keys.ctl_group_conversation_message_seq_index(conversation_id, seq)
    |> read_message_pointer(seq: seq)
  end

  defp read_message_pointer(key, expected) do
    case CasRecord.get(key) do
      {:ok, pointer} ->
        with :ok <- ConversationMessageCodec.validate_pointer(pointer, expected),
             do: {:ok, pointer}

      {:error, _reason} = error ->
        error
    end
  end

  defp message_from_pointer(group_id, conversation_id, pointer, expected) do
    with {:ok, {rows, _body}} <-
           read_message_segment(
             Keys.ctl_group_conversation_message_segment(
               group_id,
               conversation_id,
               pointer["segment_id"]
             )
           ),
         {:ok, message} <- ConversationMessageCodec.target_row(rows, pointer, expected) do
      {:ok, message}
    else
      {:error, :not_found} -> {:error, :message_pointer_target_missing}
      {:error, _reason} = error -> error
    end
  end

  defp read_message_segment(key) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        with {:ok, rows} <- ConversationMessageCodec.decode_segment(body),
             do: {:ok, {rows, body}}

      {:error, _reason} = error ->
        error
    end
  end

  defp required_message_segment_index(group_id, conversation_id, segment_id) do
    case read_json(
           Keys.ctl_group_conversation_message_segment_index(
             group_id,
             conversation_id,
             segment_id
           )
         ) do
      {:ok, index} -> {:ok, index}
      {:error, :not_found} -> {:error, :message_segment_index_missing}
      {:error, _reason} = error -> error
    end
  end

  defp read_indexed_message_segment(group_id, conversation_id, segment_id) do
    segment_key =
      Keys.ctl_group_conversation_message_segment(group_id, conversation_id, segment_id)

    with {:ok, {rows, body}} <- read_message_segment(segment_key),
         {:ok, index} <- required_message_segment_index(group_id, conversation_id, segment_id) do
      {:ok, {rows, Map.merge(index, ConversationMessageCodec.segment_facts(rows, body))}}
    end
  end

  defp merge_message_rows(acc, rows, start_seq, tail_seq) do
    selected =
      rows
      |> Enum.filter(&(&1["seq"] >= start_seq and &1["seq"] <= tail_seq))
      |> Enum.sort_by(& &1["seq"])

    merged = acc ++ selected
    row_validation = ConversationMessageCodec.validate_rows(merged)
    expected_start = if acc == [], do: start_seq, else: List.first(merged)["seq"]
    expected_seqs = Enum.to_list(expected_start..(expected_start + length(merged) - 1))

    cond do
      selected == [] ->
        {:error, :message_sequence_gap}

      Enum.map(merged, & &1["seq"]) != expected_seqs ->
        {:error, :message_sequence_gap}

      row_validation != :ok ->
        row_validation

      true ->
        {:ok, merged}
    end
  end

  # Delivery diagnostic reads.

  defp delivery_status_participant(_conversation, ""), do: {:ok, nil}

  defp delivery_status_participant(conversation, participant_id) do
    case get_participant(
           conversation["agent_group_id"],
           conversation["conversation_id"],
           participant_id
         ) do
      {:error, :not_found} -> {:ok, nil}
      other -> other
    end
  end

  defp delivery_records(group_id, conversation_id, participant_id, message_id, limit) do
    cond do
      participant_id != "" and message_id != "" ->
        delivery_id = Enum.join([group_id, conversation_id, message_id, participant_id], ":")

        case read_json(
               Keys.ctl_group_conversation_participant_delivery_state(
                 group_id,
                 conversation_id,
                 participant_id,
                 delivery_id
               )
             ) do
          {:ok, record} -> {:ok, [record]}
          {:error, :not_found} -> {:ok, []}
          {:error, _reason} = error -> error
        end

      participant_id != "" ->
        participant_delivery_records(group_id, conversation_id, participant_id, limit)

      true ->
        with {:ok, page} <- participant_page(group_id, conversation_id, limit: limit) do
          Enum.reduce_while(page.data, {:ok, []}, fn participant, {:ok, records} ->
            remaining = limit - length(records)

            if remaining <= 0 do
              {:halt, {:ok, records}}
            else
              case participant_delivery_records(
                     group_id,
                     conversation_id,
                     participant["participant_id"],
                     remaining
                   ) do
                {:ok, more} -> {:cont, {:ok, records ++ more}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end
          end)
        end
    end
  end

  defp participant_delivery_records(group_id, conversation_id, participant_id, limit) do
    prefix =
      Keys.ctl_group_conversation_participant_deliveries_prefix(
        group_id,
        conversation_id,
        participant_id
      )

    with {:ok, %{objects: objects}} <-
           S3.list(prefix, max_keys: max(limit * 4, @participant_limit)) do
      objects
      |> Enum.map(& &1.key)
      |> Enum.filter(&delivery_state_key?(prefix, &1))
      |> Enum.take(limit)
      |> Enum.reduce_while({:ok, []}, fn key, {:ok, records} ->
        case read_json(key) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp delivery_state_key?(prefix, key) do
    suffix = String.replace_prefix(key, prefix, "")

    String.starts_with?(key, prefix) and String.ends_with?(suffix, "/state.json") and
      length(String.split(suffix, "/")) == 2
  end

  defp delivery_matches?(record, participant_id, message_id) do
    (participant_id == "" or trim(record["participant_id"]) == participant_id) and
      (message_id == "" or trim(record["message_id"]) == message_id)
  end

  # One explicit Participant means at most one Session read. Aggregate reports
  # do not fan out across Agent runtimes.
  defp participant_source_progress(%{"actor_type" => "agent"} = participant) do
    with {:ok, agent} <- GroupDirectory.get_agent(participant["agent_id"]),
         session when is_binary(session) <-
           if(agent["role"] == "router",
             do: agent["router_session_id"],
             else: get_in(participant, ["payload", "session_id"])
           ),
         {:ok, progress} <-
           AgentDelivery.conversation_progress(
             participant["agent_id"],
             session,
             participant["participant_id"]
           ) do
      progress ||
        %{"status" => "not_admitted", "start_seq" => participant["source_start_seq"] || 0}
    else
      _ -> %{"status" => "unavailable"}
    end
  end

  defp participant_source_progress(_), do: nil

  defp project_participant_diagnostic(nil), do: nil

  defp project_participant_diagnostic(participant) do
    payload = participant["payload"] || %{}

    %{
      "participant_id" => participant["participant_id"],
      "actor_type" => participant["actor_type"],
      "agent_id" => participant["agent_id"],
      "provider" => participant["provider"],
      "state" => participant["state"],
      "notification_filter" => participant["notification_filter"],
      "delivery_cursor_seq" => participant["delivery_cursor_seq"],
      "session_id" => payload["session_id"],
      "connect_id" => payload["connect_id"],
      "channel_id" => payload["channel_id"],
      "thread_ts" => payload["thread_ts"]
    }
    |> strip_empty()
  end

  defp retire_old_pending_delivery(record, conversation) do
    floor = conversation["log_start_seq"]

    if record["status"] in ~w(pending retry_waiting delivering) and
         (not is_integer(record["message_seq"]) or not is_integer(floor) or
            record["message_seq"] <= floor) do
      record
      |> Map.put("status", if(record["status"] == "delivering", do: "unknown", else: "cancelled"))
      |> Map.put("last_error", "pre_cutover_backlog_discarded")
    else
      record
    end
  end

  defp project_delivery(record) do
    %{
      "delivery_id" => record["delivery_id"],
      "delivery_kind" => record["notification_kind"] || record["delivery_kind"],
      "status" => record["status"],
      "conversation_id" => record["conversation_id"],
      "message_id" => record["message_id"],
      "participant_id" => record["participant_id"],
      "participant_actor_type" => record["participant_actor_type"],
      "participant_role_label" => record["participant_role_label"],
      "participant_agent_id" => record["participant_agent_id"],
      "participant_provider" => record["participant_provider"],
      "participant_payload" => record["participant_payload"],
      "source_actor_type" => record["source_actor_type"],
      "source_participant_id" => record["source_participant_id"],
      "source_agent_id" => record["source_agent_id"],
      "source_user_id" => record["source_user_id"],
      "created_at" => record["created_at"],
      "updated_at" => record["updated_at"],
      "delivery" =>
        %{
          "delivery_status" => record["delivery_status"],
          "delivered_at" => record["delivered_at"],
          "attempts" => record["attempts"],
          "last_error" => record["last_error"],
          "delivery_result" => record["delivery_result"]
        }
        |> strip_empty()
    }
    |> strip_empty()
  end

  # Bounded search projection.

  defp search_records(conversations, q) do
    Enum.reduce_while(conversations, {:ok, []}, fn conversation, {:ok, hits} ->
      with {:ok, messages} <-
             list_group_conversation_messages(
               conversation["agent_group_id"],
               conversation["conversation_id"],
               tail: @search_message_limit
             ) do
        {:cont,
         {:ok,
          hits ++
            title_hits(conversation, q) ++
            Enum.flat_map(messages, &message_hits(conversation, &1, q))}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp search_records_by_keywords(conversations, normalized_query, terms) do
    Enum.reduce_while(conversations, {:ok, []}, fn conversation, {:ok, hits} ->
      with {:ok, messages} <-
             list_group_conversation_messages(
               conversation["agent_group_id"],
               conversation["conversation_id"],
               tail: @search_message_limit
             ) do
        candidates =
          [keyword_title_hit(conversation, normalized_query, terms)] ++
            Enum.map(
              messages,
              &keyword_message_hit(conversation, &1, normalized_query, terms)
            )

        case candidates
             |> Enum.reject(&is_nil/1)
             |> Enum.max_by(&search_sort_key/1, fn -> nil end) do
          nil -> {:cont, {:ok, hits}}
          hit -> {:cont, {:ok, [hit | hits]}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp keyword_title_hit(conversation, normalized_query, terms) do
    title = to_string(conversation["title"] || "")

    keyword_hit(title, normalized_query, terms, fn matched_terms, snippet_query ->
      %{
        "conversation_id" => conversation["conversation_id"],
        "conversation_kind" => conversation["kind"],
        "title" => title,
        "role" => "conversation",
        "created_at" => conversation["updated_at"] || conversation["created_at"] || 0,
        "updated_at" => conversation["updated_at"] || conversation["created_at"] || 0,
        "snippet" => snippet(title, snippet_query),
        "score" => length(matched_terms),
        "source" => "live"
      }
    end)
  end

  defp keyword_message_hit(conversation, message, normalized_query, terms) do
    text = ConversationMessage.visible_text(message)

    keyword_hit(text, normalized_query, terms, fn matched_terms, snippet_query ->
      %{
        "conversation_id" => conversation["conversation_id"],
        "conversation_kind" => conversation["kind"],
        "title" => conversation["title"] || "",
        "message_id" => message["message_id"],
        "role" => message["role_label"] || message["actor_type"] || "message",
        "created_at" => message["created_at"] || conversation["updated_at"] || 0,
        "updated_at" => conversation["updated_at"] || 0,
        "snippet" => snippet(text, snippet_query),
        "score" => length(matched_terms),
        "source" => "live"
      }
    end)
  end

  defp keyword_hit("", _normalized_query, _terms, _build), do: nil

  defp keyword_hit(text, normalized_query, terms, build) do
    downcased = String.downcase(text)
    matched_terms = Enum.filter(terms, &String.contains?(downcased, &1))

    if matched_terms == [] do
      nil
    else
      snippet_query =
        if String.contains?(downcased, normalized_query),
          do: normalized_query,
          else: hd(matched_terms)

      build.(matched_terms, snippet_query)
    end
  end

  defp title_hits(conversation, q) do
    title = to_string(conversation["title"] || "")

    if String.contains?(String.downcase(title), q) do
      [
        %{
          "conversation_id" => conversation["conversation_id"],
          "conversation_kind" => conversation["kind"],
          "title" => title,
          "role" => "conversation",
          "created_at" => conversation["updated_at"] || conversation["created_at"] || 0,
          "updated_at" => conversation["updated_at"] || conversation["created_at"] || 0,
          "snippet" => snippet(title, q),
          "score" => 0,
          "source" => "live"
        }
      ]
    else
      []
    end
  end

  defp message_hits(conversation, message, q) do
    text = ConversationMessage.visible_text(message)

    if text != "" and String.contains?(String.downcase(text), q) do
      [
        %{
          "conversation_id" => conversation["conversation_id"],
          "conversation_kind" => conversation["kind"],
          "title" => conversation["title"] || "",
          "message_id" => message["message_id"],
          "role" => message["role_label"] || message["actor_type"] || "message",
          "created_at" => message["created_at"] || conversation["updated_at"] || 0,
          "updated_at" => conversation["updated_at"] || 0,
          "snippet" => snippet(text, q),
          "score" => 1,
          "source" => "live"
        }
      ]
    else
      []
    end
  end

  defp snippet(content, query) do
    case :binary.match(String.downcase(content), query) do
      {index, length} ->
        character_index = content |> String.downcase() |> binary_part(0, index) |> String.length()
        character_length = query |> binary_part(0, length) |> String.length()
        start = max(character_index - 80, 0)
        stop = min(character_index + character_length + 80, String.length(content))

        String.slice(content, start, character_index - start) <>
          "«" <>
          String.slice(content, character_index, character_length) <>
          "»" <>
          String.slice(
            content,
            character_index + character_length,
            stop - character_index - character_length
          )

      :nomatch ->
        String.slice(content, 0, 160)
    end
  end

  defp search_sort_key(hit),
    do: {hit["score"] || 0, hit["created_at"] || 0, hit["conversation_id"] || ""}

  # Validation and projection helpers.

  defp project_conversation(conversation),
    do: conversation |> SalixIM.TaskArchive.project() |> Map.drop(@internal_conversation_fields)

  defp conversation_tail_seq(conversation),
    do: conversation["message_tail_seq"] || conversation["message_count"] || 0

  defp conversation_head_seq(conversation),
    do:
      conversation["message_head_seq"] ||
        if(conversation_tail_seq(conversation) > 0, do: 1, else: 0)

  defp search_query(query) do
    case query |> to_string() |> String.trim() do
      "" -> {:error, {:bad_request, "q is required"}}
      query -> {:ok, String.downcase(query)}
    end
  end

  defp keyword_terms(query) do
    terms =
      query
      |> to_string()
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}_-]+/u, trim: true)
      |> Enum.uniq()
      |> Enum.take(16)

    if terms == [], do: {:error, {:bad_request, "q is required"}}, else: {:ok, terms}
  end

  defp task_search_query(query) do
    query = to_string(query)

    case SearchDocumentEnvelope.query(query) do
      {:ok, query_envelope} ->
        {:ok, query_envelope.raw}

      {:error, :required} ->
        {:error, {:bad_request, "q is required"}}

      {:error, :null} ->
        {:error, {:bad_request, "q contains an unsupported null character"}}

      {:error, :too_short} ->
        {:error, {:bad_request, "q must contain at least 2 characters"}}

      {:error, :too_long} ->
        {:error, {:bad_request, "q must contain at most 128 characters"}}

      {:error, :invalid} ->
        {:error, {:bad_request, "invalid q"}}
    end
  end

  defp task_search_options(opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:limit, :kind, :conversation_id] == [],
         {:ok, limit} <- task_search_limit(opts[:limit]),
         true <- opts[:kind] in [nil, "agent_task"],
         :ok <-
           validate_optional_id(
             opts[:conversation_id],
             "conversation_id",
             &Ids.valid_conversation_id?/1
           ) do
      {:ok, [limit: limit] |> maybe_put_option(:conversation_id, opts[:conversation_id])}
    else
      false -> {:error, {:bad_request, "invalid search parameters"}}
      {:error, _reason} = error -> error
    end
  end

  defp task_search_options(_opts), do: {:error, {:bad_request, "invalid search parameters"}}

  defp task_search_limit(value) when value in [nil, ""], do: {:ok, 20}

  defp task_search_limit(value) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit in 1..50 -> {:ok, limit}
      _other -> {:error, {:bad_request, "limit must be between 1 and 50"}}
    end
  end

  defp maybe_put_option(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp search_limit(opts), do: clamp_limit(opts[:limit], 20, 100)

  defp strict_limit(value) when value in [nil, ""], do: {:ok, @default_limit}

  defp strict_limit(value) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit > 0 and limit <= @max_limit ->
        {:ok, limit}

      {limit, ""} when limit > @max_limit ->
        {:error, {:bad_request, "limit must be <= #{@max_limit}"}}

      _ ->
        {:error, {:bad_request, "invalid limit"}}
    end
  end

  defp strict_conversation_kind(value) when value in [nil, ""], do: {:ok, nil}

  defp strict_conversation_kind(value) when value in ["user_chat", "agent_task"],
    do: {:ok, value}

  defp strict_conversation_kind(_value),
    do: {:error, {:bad_request, "invalid conversation kind"}}

  defp optional_limit(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_limit(value), do: strict_limit(value)

  defp clamp_limit(nil, default, _max), do: default

  defp clamp_limit(value, default, max) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit > 0 -> min(limit, max)
      _ -> default
    end
  end

  defp validate_optional_seq(nil), do: :ok
  defp validate_optional_seq(seq) when is_integer(seq) and seq >= 0, do: :ok

  defp validate_optional_seq(_seq),
    do: {:error, {:bad_request, "after_seq must be a non-negative integer"}}

  defp validate_optional_id(value, _field, _validator) when value in [nil, ""], do: :ok

  defp validate_optional_id(value, field, validator),
    do: require_id(trim(value), field, validator)

  defp require_id(value, field, validator) do
    cond do
      trim(value) == "" -> {:error, {:bad_request, field <> " is required"}}
      validator.(trim(value)) -> :ok
      true -> {:error, {:bad_request, "invalid " <> field}}
    end
  end

  defp valid_participant?(%{"participant_id" => participant_id}),
    do: Ids.valid_participant_id?(participant_id)

  defp valid_participant?(_participant), do: false

  defp conversation_list_start_after(_group_id, nil), do: nil

  defp conversation_list_start_after(group_id, {updated_at, conversation_id}),
    do:
      conversation_index_key(group_id, %{
        "updated_at" => updated_at,
        "conversation_id" => conversation_id
      })

  defp encode_conversation_cursor(conversation) do
    %{
      "updated_at" => SalixIM.TaskArchive.list_timestamp(conversation),
      "conversation_id" => conversation["conversation_id"] || ""
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_conversation_cursor(value) when value in [nil, ""], do: {:ok, nil}

  defp decode_conversation_cursor(value) do
    with {:ok, json} <- Base.url_decode64(to_string(value), padding: false),
         {:ok, %{"updated_at" => updated_at, "conversation_id" => conversation_id}}
         when is_integer(updated_at) and is_binary(conversation_id) <- Jason.decode(json) do
      {:ok, {updated_at, conversation_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp encode_participant_cursor(key), do: Base.url_encode64(key, padding: false)
  defp decode_participant_cursor(value) when value in [nil, ""], do: {:ok, ""}

  defp decode_participant_cursor(value) do
    case Base.url_decode64(to_string(value), padding: false) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp read_json(key), do: CasRecord.get(key)

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_optional(map, _key, value) when value in [nil, ""], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp strip_empty(map),
    do:
      Map.new(map, fn pair -> pair end)
      |> Map.reject(fn {_key, value} -> value in [nil, "", %{}] end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
