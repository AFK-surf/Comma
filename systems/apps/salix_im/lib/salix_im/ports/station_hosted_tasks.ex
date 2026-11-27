defmodule SalixIM.Ports.StationHostedTasks do
  @moduledoc """
  Outbound port to the Tasks a station hosts: chats on the station's own page
  (`systems/station/docs/tasks.md`), which Salix knows only by the Task index
  the station sends (`SalixStore.StationTaskIndex`). The configured product
  module (`:station_hosted_tasks_mod`) asks the station over its Connector to
  read one (`task.read`) or to write in it (`task.say`); a station that is not
  connected answers neither.

  A Router names such a Task `station:<station_id>:<thread>`.
  """

  @prefix "station:"

  @doc """
  The Messages of the Task after `after` (a seq of the station's), at most
  `limit`: `{:ok, %{"title", "messages", "through"}}`, or `:device_offline`.
  """
  @callback read(scope :: map(), station_id :: String.t(), thread :: String.t(), opts :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Writes `text` into the Task as `requester`; asked again with the same `key`,
  it is one Message: `{:ok, %{"seq" => seq}}`, or `:device_offline`.
  """
  @callback say(
              scope :: map(),
              station_id :: String.t(),
              thread :: String.t(),
              text :: String.t(),
              key :: String.t(),
              requester :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @callback say(
              scope :: map(),
              station_id :: String.t(),
              thread :: String.t(),
              text :: String.t(),
              key :: String.t(),
              requester :: String.t(),
              opts :: map()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Reads one chunk of an attachment recorded on message `seq` of the Task, from
  `offset`: `{:ok, %{"name", "size", "offset", "data"}}`, `%{"missing" => why}`,
  or `:device_offline`.
  """
  @callback read_file(
              scope :: map(),
              station_id :: String.t(),
              thread :: String.t(),
              seq :: pos_integer(),
              file :: String.t(),
              offset :: non_neg_integer()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  The names of the Group's still.fail workspaces, by the device id their rows
  carry (`SalixEnv.StillfailDevices`): one bounded read.
  """
  @callback workspace_names(group_id :: String.t()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}

  @optional_callbacks workspace_names: 1, say: 7, read_file: 6

  @doc "The Router's name for a station-hosted Task."
  def ref(station_id, thread), do: @prefix <> station_id <> ":" <> thread

  @doc "`{station_id, thread}` of a station-hosted Task's name, else `:error`."
  def parse(@prefix <> rest) do
    case String.split(rest, ":", parts: 2) do
      [station_id, thread] when station_id != "" and thread != "" -> {station_id, thread}
      _ -> :error
    end
  end

  def parse(_id), do: :error

  def read(scope, station_id, thread, opts), do: call(& &1.read(scope, station_id, thread, opts))

  def read_file(scope, station_id, thread, seq, file, offset \\ 0) do
    call(fn module ->
      SystemsRuntime.Proc.ensure_loaded?(module)

      if function_exported?(module, :read_file, 6),
        do: module.read_file(scope, station_id, thread, seq, file, offset),
        else: {:error, :unsupported}
    end)
  end

  def say(scope, station_id, thread, text, key, requester, opts \\ %{}) do
    call(fn module ->
      SystemsRuntime.Proc.ensure_loaded?(module)

      if is_map(opts) and map_size(opts) > 0 and function_exported?(module, :say, 7),
        do: module.say(scope, station_id, thread, text, key, requester, opts),
        else: module.say(scope, station_id, thread, text, key, requester)
    end)
  end

  def workspace_names(group_id) do
    case SystemsRuntime.get_env(:salix_im, :station_hosted_tasks_mod) do
      nil ->
        {:error, :station_hosted_tasks_not_configured}

      module ->
        SystemsRuntime.Proc.ensure_loaded?(module)

        if function_exported?(module, :workspace_names, 1),
          do: module.workspace_names(group_id),
          else: {:ok, %{}}
    end
  end

  defp call(fun) do
    case SystemsRuntime.get_env(:salix_im, :station_hosted_tasks_mod) do
      nil -> {:error, :station_hosted_tasks_not_configured}
      module -> fun.(module)
    end
  end
end
