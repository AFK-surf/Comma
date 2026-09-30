defmodule Salix.Bindings.LocalFileImport do
  @moduledoc """
  Canonical-message-gated, ref-only local attachment read transport.

  The caller supplies an exact message id, never a message body. This module
  re-reads that committed owner fact, resolves its bound local-file ref against
  the current Registry generation, and emits the dedicated Connector
  `read_ref` method. No function accepts or returns a host path.

  The returned stream remains provisional: consumers must stage it and verify
  the terminal size/hash before publishing a VFS artifact.

  Modeled in `tla/salix/LocalFileImport.tla`.
  """

  alias SalixEnv.Protocol

  @behaviour SalixIM.Ports.LocalFileImport

  @max_bytes 512 * 1024 * 1024
  @read_lease_ms 60_000
  @max_display_name_bytes 255

  defmodule SizeError do
    @moduledoc false
    defexception [:message]
  end

  @impl true
  def materialize_delivery(agent_id, delivery),
    do: materialize_delivery(agent_id, delivery, [])

  @doc false
  def materialize_delivery(
        agent_id,
        %{
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "message_content" => content,
          "source_actor_type" => "user"
        } = delivery,
        opts
      )
      when is_binary(agent_id) and is_list(content) and is_list(opts) do
    content
    |> Enum.reduce_while({:ok, [], []}, fn
      %{"type" => "local_file"} = block, {:ok, acc, trusted} ->
        case materialize_block(
               agent_id,
               group_id,
               conversation_id,
               message_id,
               block,
               delivery,
               monotonic_ms(opts) + Keyword.get(opts, :read_lease_ms, @read_lease_ms),
               opts
             ) do
          {:ok, mapped} -> {:cont, {:ok, [mapped | acc], [mapped | trusted]}}
          {:error, _} = error -> {:halt, error}
        end

      block, {:ok, acc, trusted} ->
        {:cont, {:ok, [block | acc], trusted}}
    end)
    |> case do
      {:ok, mapped, trusted} -> {:ok, Enum.reverse(mapped), Enum.reverse(trusted)}
      error -> error
    end
  end

  def materialize_delivery(_agent_id, %{"message_content" => content}, _opts)
      when is_list(content) do
    if Enum.any?(content, &match?(%{"type" => "local_file"}, &1)),
      do: {:error, :local_file_unavailable},
      else: {:ok, content, []}
  end

  def materialize_delivery(_agent_id, _delivery, _opts),
    do: {:error, :local_file_unavailable}

  @spec read_stream(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def read_stream(group_id, conversation_id, message_id, ref, opts \\ []) do
    case admit_read_stream(group_id, conversation_id, message_id, ref, opts) do
      {:ok, stream, size, _admission} -> {:ok, stream, size}
      {:error, _} = error -> error
    end
  end

  defp admit_read_stream(group_id, conversation_id, message_id, ref, opts) do
    conversations = Keyword.get(opts, :conversations, SalixIM.Conversations)
    refs = Keyword.get(opts, :refs, SalixEnv.LocalFileRefs)
    connector = Keyword.get(opts, :connector, SalixEnv.Connector.Live)
    timeout = Keyword.get(opts, :timeout, Protocol.timeout("read_ref", %{}))

    with {:ok, message} <-
           conversations.get_group_conversation_message(group_id, conversation_id, message_id),
         ^message_id <- message["message_id"],
         {:ok, expected_size} <- local_file_size(message, ref),
         {:ok, route} <-
           refs.resolve_committed(group_id, conversation_id, message, ref) do
      params = %{
        "canonical_message_id" => message_id,
        "connection_generation" => route["connection_generation"],
        "connector_run_id" => route["connector_run_id"],
        "expected_max_bytes" => expected_size,
        "local_file_ref" => ref,
        "owner_user_id" => route["owner_user_id"],
        "stream_lease_ms" => @read_lease_ms,
        "stable_device_id" => route["stable_device_id"]
      }

      case connector.read_stream(
             route["connector_run_id"],
             Protocol.request("read_ref", params),
             timeout
           ) do
        {:ok, stream, size} ->
          {:ok, stream, size,
           %{
             conversation_id: conversation_id,
             group_id: group_id,
             message: message,
             ref: ref,
             refs: refs,
             route: route
           }}

        {:error, _} = error ->
          error
      end
    else
      _ -> {:error, :local_file_unavailable}
    end
  end

  defp local_file_size(%{"content" => content}, ref) when is_list(content) do
    case Enum.find(content, fn
           %{"type" => "local_file", "local_file_ref" => ^ref} -> true
           _ -> false
         end) do
      %{"size" => size} when is_integer(size) and size >= 0 and size <= @max_bytes ->
        {:ok, size}

      %{} = block when not is_map_key(block, "size") ->
        {:ok, @max_bytes}

      _ ->
        {:error, :local_file_unavailable}
    end
  end

  defp local_file_size(_message, _ref), do: {:error, :local_file_unavailable}

  defp materialize_block(
         agent_id,
         group_id,
         conversation_id,
         message_id,
         block,
         delivery,
         deadline,
         opts
       ) do
    ref = block["local_file_ref"]
    fingerprint = ref_fingerprint(ref)
    path = destination_path(message_id, fingerprint, block["display_name"])
    operation_id = operation_id(agent_id, message_id, fingerprint)
    workspace = Keyword.get(opts, :workspace, SalixAgent.AgentWorkspace)

    case workspace.operation_result(agent_id, operation_id) do
      {:ok, result} ->
        with :ok <- require_operation_result(result, message_id, fingerprint, path) do
          {:ok, file_block(block, result)}
        end

      {:error, :not_found} ->
        import_and_commit(
          agent_id,
          group_id,
          conversation_id,
          message_id,
          block,
          delivery,
          deadline,
          operation_id,
          fingerprint,
          path,
          opts
        )

      {:error, _} ->
        {:error, :local_file_unavailable}
    end
  end

  defp import_and_commit(
         agent_id,
         group_id,
         conversation_id,
         message_id,
         block,
         delivery,
         deadline,
         operation_id,
         fingerprint,
         path,
         opts
       ) do
    remaining = deadline - monotonic_ms(opts)

    if remaining <= 0 do
      {:error, :local_file_import_timeout}
    else
      expected_size = block["size"]
      prepare = Keyword.get(opts, :prepare, SalixAgent.StorageAuthorization)

      with {:ok, stream, reported_size, admission} <-
             admit_read_stream(
               group_id,
               conversation_id,
               message_id,
               block["local_file_ref"],
               Keyword.merge(opts, timeout: remaining)
             ),
           :ok <- require_reported_size(reported_size, expected_size),
           {:ok, event} <-
             prepare.prepare_managed_write_stream(
               agent_id,
               path,
               bounded_stream(stream, expected_size),
               billing_context: delivery["delivery_billing_context"] || %{},
               entrypoint: "local_file_import",
               actor_type: "user"
             ) do
        commit_prepared(
          agent_id,
          message_id,
          fingerprint,
          path,
          block,
          delivery,
          operation_id,
          event,
          admission,
          deadline,
          opts
        )
      else
        {:error, _} -> {:error, :local_file_unavailable}
      end
    end
  rescue
    _ -> {:error, :local_file_unavailable}
  catch
    _, _ -> {:error, :local_file_unavailable}
  end

  defp commit_prepared(
         agent_id,
         message_id,
         fingerprint,
         path,
         block,
         delivery,
         operation_id,
         event,
         admission,
         deadline,
         opts
       ) do
    workspace = Keyword.get(opts, :workspace, SalixAgent.AgentWorkspace)
    actor = Keyword.get(opts, :actor, SalixAgent.AgentActor)
    expected_size = block["size"]

    cond do
      not valid_prepared_event?(event, path, expected_size) ->
        _ = workspace.discard_prepared_write(event)
        {:error, :local_file_unavailable}

      monotonic_ms(opts) >= deadline ->
        _ = workspace.discard_prepared_write(event)
        {:error, :local_file_unavailable}

      refence_admission(admission) != :ok ->
        _ = workspace.discard_prepared_write(event)
        {:error, :local_file_unavailable}

      true ->
        result = %{
          "hash" => event["hash"],
          "path" => path,
          "size" => event["size"],
          "source_message_id" => message_id,
          "source_ref_fingerprint" => fingerprint
        }

        commit_opts = [
          actor_type: "user",
          billing_context: delivery["delivery_billing_context"] || %{},
          entrypoint: "local_file_import"
        ]

        case actor.commit_workspace_operation(
               agent_id,
               operation_id,
               result,
               [event],
               commit_opts
             ) do
          {:ok, committed} ->
            with :ok <- require_operation_result(committed, message_id, fingerprint, path) do
              {:ok, file_block(block, committed)}
            end

          {:error, _reason} ->
            settle_failed_commit(
              actor,
              agent_id,
              operation_id,
              result,
              message_id,
              fingerprint,
              path,
              block,
              event,
              commit_opts
            )
        end
    end
  end

  defp refence_admission(%{
         conversation_id: conversation_id,
         group_id: group_id,
         message: message,
         ref: ref,
         refs: refs,
         route: route
       }) do
    refs.refence_committed(group_id, conversation_id, message, ref, route)
  rescue
    _ -> {:error, :local_file_unavailable}
  catch
    _, _ -> {:error, :local_file_unavailable}
  end

  defp refence_admission(_), do: {:error, :local_file_unavailable}

  defp settle_failed_commit(
         actor,
         agent_id,
         operation_id,
         expected_result,
         message_id,
         fingerprint,
         path,
         block,
         event,
         commit_opts
       ) do
    # Re-enter the exact idempotent workspace-commit owner rather than trying
    # to infer the result from a separate read. If the first manifest PUT
    # landed but its acknowledgement was lost, the duplicate path reconciles
    # the winning managed blob and releases its durable cleanup ownership. If
    # settlement is still unavailable, retain that ownership for the existing
    # prepared-blob sweeper; deleting an unproven event could remove bytes
    # already referenced by a committed manifest.
    case actor.commit_workspace_operation(
           agent_id,
           operation_id,
           expected_result,
           [event],
           commit_opts
         ) do
      {:ok, result} ->
        with :ok <- require_operation_result(result, message_id, fingerprint, path) do
          {:ok, file_block(block, result)}
        end

      {:error, _reason} ->
        {:error, :local_file_unavailable}
    end
  end

  defp valid_prepared_event?(event, path, expected_size) do
    event["type"] == "vfs_write" and event["path"] == path and
      event["prepared_blob_cleanup"] == true and is_map(event["ref"]) and
      is_integer(event["size"]) and event["size"] >= 0 and event["size"] <= @max_bytes and
      is_binary(event["hash"]) and byte_size(event["hash"]) == 64 and
      (is_nil(expected_size) or event["size"] == expected_size)
  end

  defp require_operation_result(result, message_id, fingerprint, path) when is_map(result) do
    if result["source_message_id"] == message_id and
         result["source_ref_fingerprint"] == fingerprint and result["path"] == path and
         is_integer(result["size"]) and result["size"] >= 0 and result["size"] <= @max_bytes and
         is_binary(result["hash"]) and byte_size(result["hash"]) == 64,
       do: :ok,
       else: {:error, :local_file_operation_conflict}
  end

  defp require_operation_result(_result, _message_id, _fingerprint, _path),
    do: {:error, :local_file_operation_conflict}

  defp require_reported_size(nil, _expected), do: :ok
  defp require_reported_size(size, nil) when is_integer(size) and size in 0..@max_bytes, do: :ok
  defp require_reported_size(size, size) when is_integer(size), do: :ok
  defp require_reported_size(_reported, _expected), do: {:error, :local_file_size_mismatch}

  defp bounded_stream(stream, expected_size) do
    max = expected_size || @max_bytes

    Stream.transform(
      stream,
      fn -> 0 end,
      fn chunk, received when is_binary(chunk) ->
        next = received + byte_size(chunk)

        if next > max or next > @max_bytes do
          raise SizeError, message: "local file stream exceeds its declared limit"
        end

        {[chunk], next}
      end,
      fn received ->
        if not is_nil(expected_size) and received != expected_size do
          raise SizeError, message: "local file stream size does not match its declaration"
        end

        []
      end
    )
  end

  defp file_block(block, result) do
    %{
      "type" => "file",
      "path" => result["path"],
      "file_name" => safe_display_name(block["display_name"]),
      "mime_type" => safe_media_type(block["media_type"]),
      "size" => result["size"]
    }
  end

  defp destination_path(message_id, fingerprint, display_name) do
    "/attachments/local/#{message_id}/#{binary_part(fingerprint, 0, 16)}-#{safe_display_name(display_name)}"
  end

  defp safe_display_name(value) when is_binary(value) do
    value
    |> Path.basename()
    |> String.replace(~r/[^\p{L}\p{N}._ -]+/u, "_")
    |> String.trim()
    |> truncate_utf8(@max_display_name_bytes)
    |> case do
      value when value in ["", ".", ".."] -> "Local file"
      value -> value
    end
  end

  defp safe_display_name(_value), do: "Local file"

  defp safe_media_type(value) when is_binary(value) and value != "", do: value
  defp safe_media_type(_value), do: "application/octet-stream"

  defp truncate_utf8(value, max) when byte_size(value) <= max, do: value

  defp truncate_utf8(value, max) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= max,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end

  defp ref_fingerprint(ref) when is_binary(ref) do
    :crypto.hash(:sha256, ref) |> Base.url_encode64(padding: false)
  end

  defp ref_fingerprint(_ref), do: "invalid"

  defp operation_id(agent_id, message_id, fingerprint) do
    digest =
      :crypto.hash(:sha256, Enum.join([agent_id, message_id, fingerprint], <<0>>))
      |> Base.url_encode64(padding: false)

    "local-file-import:v1:" <> digest
  end

  defp monotonic_ms(opts) do
    case Keyword.get(opts, :monotonic_ms) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.monotonic_time(:millisecond)
    end
  end
end
