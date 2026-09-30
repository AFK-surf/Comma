defmodule Salix.Drive.Files do
  @moduledoc """
  The Synchronicity control-plane file API, driven with a group's Drive
  binding (`Salix.Drive.Handle`): one directory listing, one path's versions,
  a streamed download, a streamed upload, and a withdrawal, under
  `/api/orgs/<slug>/networks/<network>/browse/...`.

  What the API is, so callers do not expect more of it:

    * Reads answer from whichever member is attached to the control plane —
      the hosted replica `cloud-1` for a Comma Workspace — so they work with the
      user's devices offline, once `cloud-1` has replicated the content.
    * A write is published as `cloud-1`'s own version of the path. It never
      alters a version a user's device published; where one exists, both are
      visible (divergence) and the newest is selected. Devices see the write
      at their next anti-entropy round, not instantly.
    * A delete withdraws `cloud-1`'s version only. `still_published: true`
      means a user's device still asserts the path, and only that device can
      retract it. Neither that nor `withdrawn: false` is a failure.
    * Bytes per write are capped by the control plane (1 GiB by default), with
      `Content-Length` required, so a streamed upload must know its size.

  Every refusal is classified into one bounded vocabulary (`error/0`), whether
  it arrived as JSON or, from the file route, as plain `code: message`.
  """

  alias Salix.Drive.Handle

  @read_timeout 60_000
  @write_timeout 600_000
  # Pages of one directory followed before a listing is cut short.
  @max_list_pages 50

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          kind: String.t(),
          size: non_neg_integer(),
          mtime_ns: non_neg_integer(),
          versions: non_neg_integer(),
          origin: String.t(),
          root: String.t()
        }

  @type error ::
          {:error,
           :not_found
           | :auth
           | :browse_disabled
           | :hosting_disabled
           | :no_device_attached
           | :no_cloud_attached
           | :precondition
           | :too_large
           | :over_budget
           | {:retryable, term()}
           | {:invalid, term()}}

  @doc """
  The entries of one directory (`""` for the space root), every page followed
  up to a bound. Directories are `kind: "dir"`; a `tombstone` is a path whose
  selected version is a deletion.
  """
  @spec list(Handle.t(), String.t()) :: {:ok, [entry()]} | error()
  def list(%Handle{} = drive, path) when is_binary(path) do
    measured(fn -> list_pages(drive, path, "", [], 0) end)
  end

  @doc "Every version of one path, newest first as the control plane orders them."
  @spec stat(Handle.t(), String.t()) :: {:ok, %{versions: [map()]}} | error()
  def stat(%Handle{} = drive, path) when is_binary(path) do
    measured(fn ->
      case request(drive, :get, "browse/stat", params: [space: drive.space, path: path]) do
        {:ok, %Req.Response{status: 200, body: %{"versions" => versions}}}
        when is_list(versions) ->
          {:ok, %{versions: Enum.map(versions, &version/1)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, reason} ->
          {:error, {:retryable, transport_reason(reason)}}
      end
    end)
  end

  @doc """
  The bytes of one path, at most `max_bytes` of them. The third element says
  whether the file was longer than that; the download is cancelled at the cap
  rather than drained.
  """
  @spec read(Handle.t(), String.t(), pos_integer()) ::
          {:ok, binary(), boolean()} | error()
  def read(%Handle{} = drive, path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    measured(fn ->
      with {:ok, stream, _size} <- open_stream(drive, path) do
        collect_bounded(stream, max_bytes)
      end
    end)
  end

  @doc """
  A lazy stream of the bytes of one path, and its size. The stream must be
  consumed by the calling process (the download's chunks are delivered to
  it) and is cancelled when halted early.
  """
  @spec stream(Handle.t(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | error()
  def stream(%Handle{} = drive, path) when is_binary(path) do
    measured(fn -> open_stream(drive, path) end)
  end

  @doc """
  Publishes `body` (a binary, or an enumerable of binaries totalling exactly
  `size` bytes) as `cloud-1`'s version of the path. Options: `if_none_match:
  true` to create only, `if_match: root` to replace only that selected version.
  """
  @spec write(Handle.t(), String.t(), iodata() | Enumerable.t(), non_neg_integer(), keyword()) ::
          {:ok, %{root: String.t(), size: non_neg_integer(), seq: non_neg_integer()}} | error()
  def write(%Handle{} = drive, path, body, size, opts \\ [])
      when is_binary(path) and is_integer(size) and size >= 0 and is_list(opts) do
    measured(fn ->
      headers =
        [{"content-length", Integer.to_string(size)}] ++
          if(opts[:if_none_match], do: [{"if-none-match", "*"}], else: []) ++
          case opts[:if_match] do
            root when is_binary(root) -> [{"if-match", "\"" <> root <> "\""}]
            _ -> []
          end

      case request(drive, :put, "browse/file",
             params: [space: drive.space, path: path],
             headers: headers,
             body: body,
             receive_timeout: @write_timeout
           ) do
        {:ok, %Req.Response{status: 200, body: %{"root" => root} = result}} ->
          {:ok,
           %{
             root: root,
             size: integer(result["size"], size),
             seq: integer(result["seq"], 0)
           }}

        {:ok, %Req.Response{status: 200}} ->
          {:error, {:invalid, :malformed_success_body}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, reason} ->
          {:error, {:retryable, transport_reason(reason)}}
      end
    end)
  end

  @doc "Withdraws `cloud-1`'s version of the path (see the module note)."
  @spec delete(Handle.t(), String.t()) ::
          {:ok, %{withdrawn: boolean(), still_published: boolean()}} | error()
  def delete(%Handle{} = drive, path) when is_binary(path) do
    measured(fn ->
      case request(drive, :delete, "browse/file", params: [space: drive.space, path: path]) do
        {:ok, %Req.Response{status: 200, body: %{} = body}} ->
          {:ok,
           %{
             withdrawn: body["withdrawn"] == true,
             still_published: body["still_published"] == true
           }}

        {:ok, %Req.Response{status: 200}} ->
          {:error, {:invalid, :malformed_success_body}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, reason} ->
          {:error, {:retryable, transport_reason(reason)}}
      end
    end)
  end

  @doc """
  Whether the network can serve reads and take writes right now: browsing on
  with a member attached (`devices`), and the hosted replica's write tunnel
  attached (`writes.attached`).
  """
  @spec status(Handle.t()) ::
          {:ok, %{browse_enabled: boolean(), attached: boolean(), writes: boolean()}} | error()
  def status(%Handle{} = drive) do
    measured(fn ->
      case request(drive, :get, "browse", []) do
        {:ok, %Req.Response{status: 200, body: %{} = body}} ->
          writes = body["writes"] || %{}

          {:ok,
           %{
             browse_enabled: body["enabled"] == true,
             attached: attached?(body),
             writes: writes["enabled"] == true and writes["attached"] == true
           }}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, reason} ->
          {:error, {:retryable, transport_reason(reason)}}
      end
    end)
  end

  @doc """
  Maps a refusal to the bounded error vocabulary. Pure, so it is tested
  without a transport. `body` is the decoded JSON map, or the plain text the
  file route answers with (`code: message`).
  """
  @spec classify(non_neg_integer(), term()) :: term()
  def classify(status, body) do
    code = error_code(body)

    case {status, code} do
      {404, _} -> :not_found
      {status, _} when status in [401, 403] -> :auth
      {409, "browse-disabled"} -> :browse_disabled
      {409, "hosting-disabled"} -> :hosting_disabled
      {409, code} -> {:invalid, {:conflict, code}}
      {412, _} -> :precondition
      {413, _} -> :too_large
      {507, _} -> :over_budget
      {503, "no-cloud-attached"} -> :no_cloud_attached
      {503, "no-device-attached"} -> :no_device_attached
      {status, _} when status == 429 or status in 500..599 -> {:retryable, {:status, status}}
      {400, code} -> {:invalid, {:bad_request, code}}
      {status, _} -> {:invalid, {:unexpected_status, status}}
    end
  end

  # ---- transport ----

  defp request(%Handle{} = drive, method, route, opts) do
    {receive_timeout, opts} = Keyword.pop(opts, :receive_timeout, @read_timeout)
    {extra_headers, opts} = Keyword.pop(opts, :headers, [])

    options =
      [
        method: method,
        url: route_url(drive, route),
        headers: [{"authorization", "Bearer " <> drive.token} | extra_headers],
        receive_timeout: receive_timeout,
        retry: false
      ] ++ opts ++ drive.req_options

    Req.request(Req.new(options))
  end

  defp route_url(%Handle{} = drive, route) do
    drive.base_url <>
      "/api/orgs/" <>
      URI.encode(drive.org_slug) <>
      "/networks/" <> URI.encode(drive.network) <> "/" <> route
  end

  defp list_pages(_drive, _path, _cursor, acc, @max_list_pages),
    do: {:ok, acc |> Enum.reverse() |> List.flatten()}

  defp list_pages(drive, path, cursor, acc, page) do
    params = [space: drive.space, path: path] ++ if(cursor == "", do: [], else: [cursor: cursor])

    case request(drive, :get, "browse/ls", params: params) do
      {:ok, %Req.Response{status: 200, body: %{"entries" => entries} = body}}
      when is_list(entries) ->
        acc = [Enum.map(entries, &entry/1) | acc]

        case body["cursor"] do
          next when is_binary(next) and next != "" and next != cursor ->
            list_pages(drive, path, next, acc, page + 1)

          _ ->
            {:ok, acc |> Enum.reverse() |> List.flatten()}
        end

      {:ok, %Req.Response{status: 200}} ->
        {:error, {:invalid, :malformed_success_body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, classify(status, body)}

      {:error, reason} ->
        {:error, {:retryable, transport_reason(reason)}}
    end
  end

  # Opens the download and hands back a lazy stream over its chunks. The
  # response headers have arrived when this returns, so a refusal is
  # classified here; only the body is deferred.
  defp open_stream(drive, path) do
    case request(drive, :get, "browse/file",
           params: [space: drive.space, path: path],
           into: :self
         ) do
      {:ok, %Req.Response{status: 200} = response} ->
        {:ok, chunk_stream(response), content_length(response)}

      {:ok, %Req.Response{status: status} = response} ->
        {:error, classify(status, drain_text(response))}

      {:error, reason} ->
        {:error, {:retryable, transport_reason(reason)}}
    end
  end

  defp chunk_stream(%Req.Response{body: %Req.Response.Async{}} = response) do
    Stream.resource(
      fn -> {response, :open} end,
      fn
        {response, :open} -> next_chunks(response)
        {response, :done} -> {:halt, {response, :done}}
      end,
      fn
        {response, :open} -> Req.cancel_async_response(response)
        {_response, :done} -> :ok
      end
    )
  end

  # A non-async body (a test transport that answered whole) streams as one chunk.
  defp chunk_stream(%Req.Response{body: body}) when is_binary(body), do: [body]
  defp chunk_stream(%Req.Response{body: body}), do: [IO.iodata_to_binary(body)]

  defp next_chunks(response) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, parts} ->
            data = for {:data, chunk} <- parts, do: chunk
            state = if :done in parts, do: :done, else: :open
            {data, {response, state}}

          :unknown ->
            next_chunks(response)
        end
    after
      @read_timeout ->
        raise "synchronicity download stalled"
    end
  end

  defp drain_text(%Req.Response{body: %Req.Response.Async{}} = response) do
    case collect_bounded(chunk_stream(response), 64 * 1024) do
      {:ok, text, _truncated} -> text
      _ -> ""
    end
  end

  defp drain_text(%Req.Response{body: body}), do: body

  defp collect_bounded(stream, max_bytes) do
    {chunks, size, truncated} =
      Enum.reduce_while(stream, {[], 0, false}, fn chunk, {acc, size, _} ->
        size = size + byte_size(chunk)

        if size > max_bytes do
          {:halt, {[chunk | acc], size, true}}
        else
          {:cont, {[chunk | acc], size, false}}
        end
      end)

    body = acc_binary(chunks)

    if truncated or size > max_bytes,
      do: {:ok, binary_part(body, 0, max_bytes), true},
      else: {:ok, body, false}
  rescue
    error -> {:error, {:retryable, {:download, Exception.message(error)}}}
  end

  defp acc_binary(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> size
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `browse_api.status` lists the members attached for reads under `devices`
  # (control-plane `api/browse_api.gleam`, `status`); the hosted replica is
  # one of them once it has attached its browse tunnel.
  defp attached?(%{"devices" => devices}) when is_list(devices), do: devices != []
  defp attached?(_body), do: false

  # ---- shapes ----

  defp entry(%{} = raw) do
    %{
      name: string(raw["name"]),
      path: string(raw["path"]),
      kind: string(raw["kind"]),
      size: integer(raw["size"], 0),
      mtime_ns: integer(raw["mtime_ns"], 0),
      versions: integer(raw["versions"], 0),
      origin: string(raw["origin"]),
      root: string(raw["root"])
    }
  end

  defp version(%{} = raw) do
    %{
      root: string(raw["root"]),
      kind: string(raw["kind"]),
      size: integer(raw["size"], 0),
      mtime_ns: integer(raw["mtime_ns"], 0),
      seq: integer(raw["seq"], 0),
      attestors: List.wrap(raw["attestors"]) |> Enum.filter(&is_binary/1)
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp integer(_value, default), do: default

  # JSON refusals carry `error.code`; the file route answers plain
  # `code: message`. Both come back as the bare code.
  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code

  defp error_code(text) when is_binary(text) do
    case String.split(text, ":", parts: 2) do
      [code, _rest] -> String.trim(code)
      [code] -> String.trim(code)
    end
  end

  defp error_code(_body), do: nil

  defp transport_reason(%{__struct__: struct, reason: reason}), do: {struct, reason}
  defp transport_reason(%{__struct__: struct}), do: struct
  defp transport_reason(reason), do: reason

  # One bounded operation label for every file call; the outcome vocabulary
  # is `Salix.Telemetry`'s.
  defp measured(fun) do
    started_at = System.monotonic_time()

    try do
      result = fun.()
      emit(outcome(result), started_at)
      result
    catch
      kind, reason ->
        emit("error", started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit(outcome, started_at) do
    Salix.Telemetry.emit_operation(
      "salix_web",
      "drive_files",
      :salix,
      outcome,
      System.monotonic_time() - started_at
    )
  end

  defp outcome({:ok, _}), do: "ok"
  defp outcome({:ok, _, _}), do: "ok"
  defp outcome({:error, :not_found}), do: "other"
  defp outcome({:error, :auth}), do: "rejected"
  defp outcome({:error, :precondition}), do: "conflict"
  defp outcome({:error, reason}) when reason in [:too_large, :over_budget], do: "rejected"

  defp outcome({:error, reason})
       when reason in [
              :browse_disabled,
              :hosting_disabled,
              :no_device_attached,
              :no_cloud_attached
            ],
       do: "unavailable"

  defp outcome({:error, {:retryable, _}}), do: "unavailable"
  defp outcome({:error, {:invalid, _}}), do: "rejected"
  defp outcome(_), do: "other"
end
