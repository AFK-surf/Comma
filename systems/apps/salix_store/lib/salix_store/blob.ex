defmodule SalixStore.Blob do
  @moduledoc """
  VFS body storage. Content is stored immutably,
  write-once under the canonical `blobs/{uuid}` namespace, addressed by a
  fresh UUID.

  The 10MB tool-level full-read/write cap for `put/2` and `get/2` is constant
  here. Streaming copy uses `stream/2` and
  `put_stream/2`, which stay chunked and use S3 multipart upload instead of
  full-file buffering. Bodies are never mutated or conditionally written — the
  UUID guarantees uniqueness. A freshly prepared body may be discarded when
  its enclosing event fails before the manifest commit; committed manifest
  deletes never touch the body (deletes keep blobs for historical/forked
  versions).
  """

  alias SalixStore.{S3, Keys}

  @max_bytes 10 * 1024 * 1024
  @stream_chunk_size 256 * 1024
  @multipart_part_size 5 * 1024 * 1024

  @type ref :: %{kind: String.t(), uuid: String.t(), size: non_neg_integer(), hash: String.t()}

  def max_bytes, do: @max_bytes

  @doc """
  Store `content` immutably and return a content ref. Rejects bodies over the
  10MB cap.
  """
  @spec put(String.t(), binary()) :: {:ok, ref()} | {:error, :too_large} | {:error, term()}
  def put(_agent_id, content) when is_binary(content) do
    size = byte_size(content)

    if size > @max_bytes do
      {:error, :too_large}
    else
      write(Keys.blob(uuid()), content, size)
    end
  end

  @doc "Store a body as an uncommitted workspace preparation with durable cleanup ownership."
  @spec put_prepared(String.t(), binary()) ::
          {:ok, ref()} | {:error, :too_large} | {:error, term()}
  def put_prepared(agent_id, content) when is_binary(agent_id) and is_binary(content) do
    size = byte_size(content)

    if size > @max_bytes do
      {:error, :too_large}
    else
      with {:ok, state} <- put_stream_init_prepared(agent_id),
           {:ok, ref} <- write(state.key, content, size),
           :ok <- mark_prepared(state) do
        {:ok, ref}
      end
    end
  end

  @doc "Fetch a body by ref. Returns `{:error, :too_large}` if over the read cap."
  @spec get(String.t(), ref()) :: {:ok, binary()} | {:error, term()}
  def get(agent_id, %{} = ref) do
    if ref_size(ref) > @max_bytes do
      {:error, :too_large}
    else
      case S3.get(key_for(agent_id, ref)) do
        {:ok, %{body: body}} -> {:ok, body}
        other -> other
      end
    end
  end

  @doc "Stream a body by ref in bounded chunks. Streaming reads are not full-read capped."
  @spec stream(String.t(), ref()) :: {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  def stream(agent_id, %{} = ref) do
    size = ref_size(ref)
    key = key_for(agent_id, ref)
    {:ok, ranged_stream(key, size), size}
  end

  @doc "Store an enumerable body immutably without carrying it as one RPC payload."
  @spec put_stream(String.t(), Enumerable.t()) ::
          {:ok, ref()} | {:error, term()}
  def put_stream(agent_id, stream) do
    do_put_stream(put_stream_init(agent_id), stream)
  end

  @doc "Stream an uncommitted workspace preparation with durable cleanup ownership."
  @spec put_stream_prepared(String.t(), Enumerable.t()) :: {:ok, ref()} | {:error, term()}
  def put_stream_prepared(agent_id, stream) when is_binary(agent_id) do
    case put_stream_init_prepared(agent_id) do
      {:ok, init} -> do_put_stream(init, stream)
      {:error, _} = error -> error
    end
  end

  defp do_put_stream(init, stream) do
    state_key = {__MODULE__, :put_stream_state, make_ref()}
    init = Map.put(init, :state_key, state_key)
    checkpoint_stream_state(init)

    result =
      try do
        Enum.reduce_while(stream, {:ok, init}, fn chunk, {:ok, state} ->
          case put_stream_step(state, chunk) do
            {:ok, state} ->
              checkpoint_stream_state(state)
              {:cont, {:ok, state}}

            {:error, reason, state} ->
              checkpoint_stream_state(state)
              {:halt, {:error, reason, state}}
          end
        end)
      rescue
        e -> {:error, e, Process.get(state_key, init)}
      catch
        kind, reason -> {:error, {kind, reason}, Process.get(state_key, init)}
      after
        Process.delete(state_key)
      end

    case result do
      {:ok, state} ->
        finish_put_stream(state)

      {:error, reason, state} ->
        put_stream_abort(state)
        {:error, reason}
    end
  end

  @typedoc "Opaque accumulator for the step-wise streaming-upload API."
  @opaque stream_state :: map()

  @doc """
  Step-wise streaming upload, for producers that drive their own read loop (and
  thus carry their own backpressure, e.g. an HTTP body reader). Pair with
  `put_stream_step/2`, then `put_stream_finish/1` (or `put_stream_abort/1`).
  """
  @spec put_stream_init(String.t()) :: stream_state()
  def put_stream_init(agent_id) do
    %{
      agent_id: agent_id,
      mode: :buffer,
      buffer: "",
      size: 0,
      hash_ctx: :crypto.hash_init(:sha256),
      key: nil,
      upload_id: nil,
      part_number: 1,
      parts: [],
      part_buffer: "",
      cleanup_key: nil,
      state_key: nil
    }
  end

  defp put_stream_init_prepared(agent_id) do
    key = Keys.blob(uuid())
    cleanup_key = Keys.prepared_blob_cleanup(key_uuid(key))
    now = System.system_time(:second)

    record = %{
      "version" => 1,
      "agent_id" => agent_id,
      "blob_uuid" => key_uuid(key),
      "blob_key" => key,
      "upload_id" => nil,
      "status" => "preparing",
      "created_at" => now,
      "updated_at" => now
    }

    case S3.put(cleanup_key, Jason.encode!(record), if_none_match: "*") do
      {:ok, _} ->
        {:ok, %{put_stream_init(agent_id) | key: key, cleanup_key: cleanup_key}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Feed one chunk; uploads a part once enough bytes have accumulated."
  @spec put_stream_step(stream_state(), iodata()) ::
          {:ok, stream_state()} | {:error, term(), stream_state()}
  def put_stream_step(state, chunk) do
    chunk = IO.iodata_to_binary(chunk)

    state = %{
      state
      | size: state.size + byte_size(chunk),
        hash_ctx: :crypto.hash_update(state.hash_ctx, chunk)
    }

    append_stream_chunk(state, chunk)
  end

  @doc "Finalize the upload and return the content ref."
  @spec put_stream_finish(stream_state()) :: {:ok, ref()} | {:error, term()}
  def put_stream_finish(state), do: finish_streamed_body(state)

  @doc "Abort an in-flight multipart upload."
  @spec put_stream_abort(stream_state()) :: :ok
  def put_stream_abort(state), do: abort_multipart(state)

  @doc "Release durable cleanup ownership after a manifest has committed this ref."
  @spec adopt(ref()) :: :ok | {:error, term()}
  def adopt(%{} = ref) do
    with :ok <- mark_committed(ref) do
      delete_cleanup_intent(ref)
    end
  end

  @doc "Discard a freshly prepared blob that has not been committed to a manifest."
  @spec discard(ref()) :: :ok | {:error, term()}
  def discard(%{} = ref) do
    case S3.delete(key_for(nil, ref)) do
      :ok -> delete_cleanup_intent(ref)
      {:error, :not_found} -> delete_cleanup_intent(ref)
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_blob_ref}
  end

  # ---- internal ----

  defp ranged_stream(_key, 0), do: []

  defp ranged_stream(key, size) do
    Stream.resource(
      fn -> 0 end,
      fn offset ->
        if offset >= size do
          {:halt, offset}
        else
          len = min(@stream_chunk_size, size - offset)

          case S3.get(key, range: {offset, len}) do
            {:ok, %{body: body}} when byte_size(body) > 0 ->
              {[body], offset + byte_size(body)}

            {:ok, %{body: ""}} ->
              raise "blob stream read failed: empty range at #{offset}"

            {:error, reason} ->
              raise "blob stream read failed: #{inspect(reason)}"
          end
        end
      end,
      fn _offset -> :ok end
    )
  end

  defp finish_streamed_body(%{mode: :buffer, key: key, buffer: body, size: size} = state)
       when is_binary(key) do
    with {:ok, ref} <- write(key, body, size),
         :ok <- mark_prepared(state) do
      {:ok, ref}
    end
  end

  defp finish_streamed_body(%{mode: :buffer, buffer: body, size: size}) do
    key = Keys.blob(uuid())
    write(key, body, size)
  end

  defp finish_streamed_body(%{mode: :multipart} = state) do
    case upload_final_part(state) do
      {:ok, completed_state} ->
        case S3.multipart_complete(
               completed_state.key,
               completed_state.upload_id,
               Enum.reverse(completed_state.parts)
             ) do
          {:ok, _} ->
            hash = :crypto.hash_final(completed_state.hash_ctx) |> Base.encode16(case: :lower)
            ref = ref_for(completed_state.key, completed_state.size, hash)

            case mark_prepared(%{completed_state | upload_id: nil}) do
              :ok -> {:ok, ref}
              {:error, reason} -> {:error, reason}
            end

          {:error, {:ambiguous, _} = reason} ->
            # Completion may have materialized the immutable object even though
            # its acknowledgement was lost.  A managed preparation keeps its
            # durable intent so the sweeper can delete both possible outcomes;
            # aborting here would incorrectly erase that recovery ownership.
            if is_nil(completed_state.cleanup_key) do
              cleanup_ambiguous_raw_completion(completed_state)
            end

            {:error, reason}

          {:error, reason} ->
            abort_multipart(completed_state)
            {:error, reason}
        end

      {:error, reason} ->
        abort_multipart(state)
        {:error, reason}
    end
  end

  defp append_stream_chunk(%{mode: :buffer} = state, chunk) do
    body = state.buffer <> chunk

    if byte_size(body) < @multipart_part_size do
      {:ok, %{state | buffer: body}}
    else
      key = state.key || Keys.blob(uuid())

      case S3.multipart_create(key) do
        {:ok, upload_id} ->
          next = %{
            state
            | mode: :multipart,
              key: key,
              upload_id: upload_id,
              buffer: "",
              part_buffer: body
          }

          # Checkpoint the upload id before the first backend part call can
          # raise.  Managed uploads also persist it so a different process can
          # abort after task kill or node restart.
          checkpoint_stream_state(next)

          with :ok <- persist_upload_id(next) do
            upload_full_parts(next)
          else
            {:error, reason} -> {:error, reason, next}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp append_stream_chunk(%{mode: :multipart} = state, chunk) do
    %{state | part_buffer: state.part_buffer <> chunk}
    |> upload_full_parts()
  end

  defp upload_full_parts(%{part_buffer: buffer} = state) do
    if byte_size(buffer) >= @multipart_part_size do
      <<part::binary-size(@multipart_part_size), rest::binary>> = buffer

      case S3.multipart_upload_part(state.key, state.upload_id, state.part_number, part) do
        {:ok, %{etag: etag}} ->
          next = %{
            state
            | part_buffer: rest,
              part_number: state.part_number + 1,
              parts: [%{part_number: state.part_number, etag: etag} | state.parts]
          }

          checkpoint_stream_state(next)
          upload_full_parts(next)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  defp upload_final_part(%{part_buffer: ""} = state), do: {:ok, state}

  defp upload_final_part(%{part_buffer: buffer} = state) do
    case S3.multipart_upload_part(state.key, state.upload_id, state.part_number, buffer) do
      {:ok, %{etag: etag}} ->
        {:ok,
         %{
           state
           | part_buffer: "",
             part_number: state.part_number + 1,
             parts: [%{part_number: state.part_number, etag: etag} | state.parts]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp abort_multipart(%{mode: :multipart, key: key, upload_id: upload_id})
       when is_binary(key) and is_binary(upload_id) do
    case S3.multipart_abort(key, upload_id) do
      :ok -> maybe_delete_cleanup_intent_by_key(key)
      {:error, :not_found} -> maybe_delete_cleanup_intent_by_key(key)
      {:error, _} -> :ok
    end
  end

  defp abort_multipart(_state), do: :ok

  defp cleanup_ambiguous_raw_completion(%{key: key, upload_id: upload_id}) do
    _ = S3.multipart_abort(key, upload_id)
    _ = S3.delete(key)
    :ok
  end

  defp write(key, content, size) do
    uuid = key_uuid(key)

    case S3.put(key, content) do
      {:ok, _} -> {:ok, %{kind: "blob", uuid: uuid, size: size, hash: hash(content)}}
      other -> other
    end
  end

  defp finish_put_stream(state) do
    try do
      put_stream_finish(state)
    rescue
      e ->
        put_stream_abort(state)
        {:error, e}
    catch
      kind, reason ->
        put_stream_abort(state)
        {:error, {kind, reason}}
    end
  end

  defp checkpoint_stream_state(%{state_key: state_key} = state) when not is_nil(state_key),
    do: Process.put(state_key, state)

  defp checkpoint_stream_state(_state), do: :ok

  defp persist_upload_id(%{cleanup_key: nil}), do: :ok

  defp persist_upload_id(%{cleanup_key: cleanup_key} = state) do
    update_cleanup_intent(cleanup_key, fn record ->
      record
      |> Map.put("upload_id", state.upload_id)
      |> Map.put("status", "uploading")
    end)
  end

  defp mark_prepared(%{cleanup_key: nil}), do: :ok

  defp mark_prepared(%{cleanup_key: cleanup_key}) do
    update_cleanup_intent(cleanup_key, fn record ->
      record
      |> Map.put("upload_id", nil)
      |> Map.put("status", "prepared")
    end)
  end

  defp mark_committed(ref) do
    cleanup_key = cleanup_key_for_ref(ref)

    case update_cleanup_intent(cleanup_key, fn record ->
           record
           |> Map.put("upload_id", nil)
           |> Map.put("status", "committed")
         end) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp update_cleanup_intent(cleanup_key, fun) do
    with {:ok, %{body: body}} <- S3.get(cleanup_key),
         {:ok, record} <- Jason.decode(body),
         next <- fun.(record) |> Map.put("updated_at", System.system_time(:second)),
         {:ok, _} <- S3.put(cleanup_key, Jason.encode!(next)) do
      :ok
    end
  end

  defp delete_cleanup_intent(ref) do
    ref
    |> cleanup_key_for_ref()
    |> delete_cleanup_key()
  end

  defp maybe_delete_cleanup_intent_by_key(key) do
    cleanup_key = Keys.prepared_blob_cleanup(key_uuid(key))

    case S3.get(cleanup_key) do
      {:ok, _} -> delete_cleanup_key(cleanup_key)
      {:error, :not_found} -> :ok
      {:error, _} -> :ok
    end
  end

  defp delete_cleanup_key(cleanup_key) do
    case S3.delete(cleanup_key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp cleanup_key_for_ref(%{uuid: uuid}), do: Keys.prepared_blob_cleanup(uuid)
  defp cleanup_key_for_ref(%{"uuid" => uuid}), do: Keys.prepared_blob_cleanup(uuid)

  defp ref_for(key, size, hash),
    do: %{kind: "blob", uuid: key_uuid(key), size: size, hash: hash}

  defp key_for(_agent_id, %{kind: "blob", uuid: uuid}), do: Keys.blob(uuid)
  defp key_for(_agent_id, %{"kind" => "blob", "uuid" => uuid}), do: Keys.blob(uuid)

  defp ref_size(%{size: s}), do: s
  defp ref_size(%{"size" => s}), do: s
  defp ref_size(_), do: 0

  defp uuid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp key_uuid(key), do: key |> String.split("/") |> List.last()
  defp hash(content), do: SalixStore.Crypto.hex(content)
end
