defmodule CommaLog do
  @moduledoc """
  Shared opt-in verbose JSONL diagnostic log: one JSON object per line, appended
  to a single file. Used by both Salix and BridgeForTeams so the whole release
  emits one unified structured stream. **Disabled by default.**

  ## Enabling

  Resolution order (`resolve_path/2`):

    1. `--log-file <path>` / `--log-file=<path>` on the command line — read from
       `System.argv/0` and `:init.get_plain_arguments/0`, so it works with
       `mix run --no-halt -- --log-file comma.jsonl` and any invocation that
       forwards plain args;
    2. `{:comma_log, :log_file}` app env, then the legacy `{:salix_store, :log_file}`
       (back-compat with Salix's config.json `log.file`).

  ## Shape

  Every line carries `ts` (ISO8601, µs), `event`, `node`, and `pid`, plus the
  caller's fields. Fields are sanitized to JSON-safe terms before encoding:
  tuples become lists, atoms become strings, structs/pids/refs are `inspect`ed,
  long strings are truncated, and values under secret-looking keys
  (api_key/token/password/...) are redacted — so a log call can never crash a
  caller or leak credentials.

  `log/2` costs one `:persistent_term` read when disabled. When enabled, the
  caller sanitizes its fields and casts to this GenServer — the single device
  owner — which serializes the appends.
  """

  use GenServer
  require Logger

  @enabled_key {__MODULE__, :enabled?}
  @max_string 8 * 1024
  @max_depth 12

  # ---- API ----

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Cheap enabled check (one :persistent_term read)."
  @spec enabled?() :: boolean()
  def enabled?, do: :persistent_term.get(@enabled_key, false)

  @doc """
  Append one entry. A no-op unless logging is enabled. `fields` is a map or
  keyword list; reserved keys (`ts`/`event`/`node`/`pid`) win over fields.
  """
  @spec log(String.t(), map() | keyword()) :: :ok
  def log(event, fields \\ %{}) when is_binary(event) do
    if enabled?() do
      entry =
        fields
        |> Map.new()
        |> jsonable()
        |> Map.merge(%{
          "ts" => timestamp(),
          "event" => event,
          "node" => Atom.to_string(node()),
          "pid" => inspect(self())
        })

      GenServer.cast(__MODULE__, {:write, entry})
    end

    :ok
  end

  @doc "Enable logging to `path` at runtime (reopens if already enabled)."
  @spec enable(String.t()) :: :ok | {:error, term()}
  def enable(path) when is_binary(path), do: GenServer.call(__MODULE__, {:enable, path})

  @doc "Disable logging and close the file."
  @spec disable() :: :ok
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Block until all casts queued before this call are written (tests)."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "The active log file path, or nil when disabled."
  @spec path() :: String.t() | nil
  def path, do: GenServer.call(__MODULE__, :path)

  @doc """
  Resolve the configured log path: `--log-file` flag → `{:comma_log, :log_file}` /
  `{:salix_store, :log_file}` app env → nil (disabled).
  """
  @spec resolve_path([String.t()] | nil) :: String.t() | nil
  def resolve_path(argv \\ nil) do
    argv = argv || System.argv() ++ Enum.map(:init.get_plain_arguments(), &to_string/1)

    flag_value(argv) ||
      Application.get_env(:comma_log, :log_file) ||
      Application.get_env(:salix_store, :log_file)
  end

  defp flag_value(["--log-file", path | _]), do: path
  defp flag_value(["--log-file=" <> path | _]), do: present(path)
  defp flag_value([_ | rest]), do: flag_value(rest)
  defp flag_value([]), do: nil

  defp present(""), do: nil
  defp present(value), do: value

  # ---- GenServer ----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, open(%{device: nil, path: nil}, Keyword.get(opts, :path) || resolve_path())}
  end

  @impl true
  def handle_cast({:write, _entry}, %{device: nil} = state), do: {:noreply, state}

  def handle_cast({:write, entry}, state) do
    write_line(state.device, entry)
    {:noreply, state}
  end

  @impl true
  def handle_call({:enable, path}, _from, state) do
    case open(close(state), path) do
      %{device: nil} = state -> {:reply, {:error, :open_failed}, state}
      state -> {:reply, :ok, state}
    end
  end

  def handle_call(:disable, _from, state), do: {:reply, :ok, close(state)}
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state) do
    _ = close(state)
    :ok
  end

  defp open(state, nil), do: state

  defp open(state, path) do
    case File.open(path, [:append, :raw, :binary]) do
      {:ok, device} ->
        :persistent_term.put(@enabled_key, true)
        state = %{state | device: device, path: path}

        write_line(device, %{
          "ts" => timestamp(),
          "event" => "log_opened",
          "node" => Atom.to_string(node()),
          "pid" => inspect(self())
        })

        state

      {:error, reason} ->
        Logger.warning("comma jsonl log: cannot open #{path}: #{inspect(reason)}")
        state
    end
  end

  defp close(%{device: nil} = state), do: state

  defp close(state) do
    :persistent_term.put(@enabled_key, false)
    _ = :file.close(state.device)
    %{state | device: nil, path: nil}
  end

  defp write_line(device, entry) do
    iodata =
      try do
        Jason.encode_to_iodata!(entry)
      rescue
        e ->
          Jason.encode_to_iodata!(%{
            "event" => "log_encode_error",
            "error" => Exception.message(e),
            "raw" => inspect(entry, limit: 100, printable_limit: 1024)
          })
      end

    _ = :file.write(device, [iodata, ?\n])
    :ok
  end

  defp timestamp do
    System.system_time(:microsecond)
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  # ---- sanitization ----

  @doc """
  Convert an arbitrary term into a JSON-encodable one. Secret-looking map keys
  have their values redacted; long strings are truncated; non-JSON terms are
  `inspect`ed. Never raises.
  """
  @spec jsonable(term()) :: term()
  def jsonable(term), do: jsonable(term, 0)

  defp jsonable(_term, depth) when depth > @max_depth, do: "[max depth]"
  defp jsonable(term, _) when is_nil(term) or is_boolean(term) or is_number(term), do: term
  defp jsonable(atom, _) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(bin, _) when is_binary(bin), do: string(bin)
  defp jsonable(%DateTime{} = dt, _), do: DateTime.to_iso8601(dt)
  defp jsonable(%NaiveDateTime{} = dt, _), do: NaiveDateTime.to_iso8601(dt)
  defp jsonable(%MapSet{} = ms, depth), do: jsonable(MapSet.to_list(ms), depth)
  defp jsonable(%_{} = struct, _), do: inspect(struct, limit: 25, printable_limit: 256)

  defp jsonable(map, depth) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = key_string(k)

      if redact?(key) and not is_nil(v) do
        {key, "[redacted]"}
      else
        {key, jsonable(v, depth + 1)}
      end
    end)
  end

  defp jsonable(list, depth) when is_list(list) do
    if proper_list?(list),
      do: Enum.map(list, &jsonable(&1, depth + 1)),
      else: inspect(list, limit: 50)
  end

  defp jsonable(tuple, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> jsonable(depth)

  defp jsonable(other, _), do: inspect(other)

  defp key_string(k) when is_binary(k), do: if(String.valid?(k), do: k, else: inspect(k))
  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(k), do: inspect(k)

  defp redact?(key) do
    Regex.match?(
      ~r/api[-_]?key|secret|token|password|authorization|credential|query[-_]?string|prompt|completion|tool[-_]?(arguments|result)|command/i,
      key
    )
  end

  defp string(s) do
    cond do
      not String.valid?(s) -> "<<#{byte_size(s)} bytes of non-UTF8 binary>>"
      byte_size(s) <= @max_string -> s
      true -> String.slice(s, 0, @max_string) <> "…[truncated, #{byte_size(s)} bytes total]"
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
