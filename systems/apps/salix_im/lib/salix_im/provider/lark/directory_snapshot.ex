defmodule SalixIM.Provider.Lark.DirectorySnapshot do
  @moduledoc """
  The stored copy of a Lark connect's Contacts data range, which
  `Directory.lookup/4` matches a name against before it walks the directory.

  One record per connect holds everyone `Directory.list/2` lists (name,
  English name, emails, employee number, job title, open_id and department
  paths), merged by open_id in listing order, at most 20,000 people.
  `sync/2` reads the data range with `Directory.list/2`, at most 25 calls
  (3,000 directory requests) per run, and replaces `people` wholesale only
  when a run read the whole range, so people who left the range drop out
  then. A run that stops before the end keeps its people in `pending` with
  `continue_from`, the next run goes on from there, and lookups keep using
  the last whole copy. A data range that changed under a run starts it
  again from the beginning.

  One run at a time per connect, across nodes: a run claims the record by
  `sync_started_at` and refreshes the claim as it stores each call; a claim
  older than 10 minutes is free. A sync starts in the background
  (`schedule/1`) when the connect is made or its app changes, and when a
  lookup finds the copy missing, unfinished or older than a day. A run that
  ended without the whole range starts again no sooner than 10 minutes
  after it ended.

  The copy is disposable: Lark owns the directory, and the next sync
  rebuilds the copy. Retiring the connect deletes it.
  """

  require Logger

  import SalixIM.Provider.Util, only: [str: 1]

  alias SalixIM.Provider.Lark.Directory
  alias SalixIM.ProviderConnects
  alias SalixStore.{CasRecord, Keys, S3}

  @provider "lark"
  @max_calls 25
  @lease_ms 10 * 60_000
  @retry_ms 10 * 60_000
  @refresh_ms 24 * 60 * 60_000
  @max_people 20_000
  @max_bytes 16_000_000
  @task_supervisor SalixIM.DirectorySyncTasks
  @too_many "More than #{@max_people} people are in the Contacts data range, too many to store."

  @doc "The connect's stored copy, or `nil` when there is none or it cannot be read."
  @spec read(map()) :: map() | nil
  def read(%{"connect_id" => connect_id}) when is_binary(connect_id) and connect_id != "" do
    case CasRecord.get_bounded(Keys.ctl_im_lark_directory(connect_id), @max_bytes) do
      {:ok, snapshot, _size} -> snapshot
      _missing -> nil
    end
  end

  def read(_connect), do: nil

  @doc """
  Starts a background sync when `snapshot` (from `read/1`) is missing,
  unfinished or older than a day, and no run holds it. Never waits for it.
  """
  @spec refresh_if_due(map(), map() | nil) :: :ok
  def refresh_if_due(connect, snapshot) do
    if due?(snapshot, now()), do: schedule(connect), else: :ok
  end

  defp due?(nil, _now), do: true

  defp due?(snapshot, now) do
    cond do
      claimed?(snapshot, now) -> false
      snapshot["complete"] == true -> now - num(snapshot["synced_at"]) >= @refresh_ms
      true -> now - num(snapshot["run_at"]) >= @retry_ms
    end
  end

  @doc """
  Starts `sync/2` for the connect in the background. A full pool or a
  disabled sync (`config :salix_im, :directory_sync, false`) starts nothing;
  a later trigger asks again.
  """
  @spec schedule(map()) :: :ok
  def schedule(%{"group_id" => group_id, "connect_id" => connect_id})
      when is_binary(group_id) and is_binary(connect_id) do
    if SystemsRuntime.get_env(:salix_im, :directory_sync, true) != false do
      case SystemsRuntime.TaskSupervisor.start_child(@task_supervisor, fn ->
             sync_connect(group_id, connect_id)
           end) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.debug("lark directory sync not started: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  def schedule(_connect), do: :ok

  defp sync_connect(group_id, connect_id) do
    case ProviderConnects.get_active_connect_by_id(group_id, connect_id, @provider) do
      {:ok, connect} -> sync(connect)
      _gone -> :ok
    end
  rescue
    error ->
      Logger.warning("lark directory sync failed: #{inspect(error.__struct__)}")
      {:error, :sync_failed}
  catch
    :exit, _reason -> {:error, :sync_failed}
  end

  @doc """
  Reads the connect's data range into its stored copy, going on from where
  an unfinished run stopped. Returns `:ok` when the copy is whole,
  `:incomplete` when the run used its #{@max_calls} calls (`max_calls:`
  lowers it), `:busy` when another run holds the copy, or `{:error, reason}`
  when a read failed; the record keeps the error and the progress.
  """
  @spec sync(map(), keyword()) :: :ok | :incomplete | :busy | {:error, term()}
  def sync(%{"connect_id" => connect_id} = connect, opts \\ []) when is_binary(connect_id) do
    key = Keys.ctl_im_lark_directory(connect_id)

    case claim(key, connect_id) do
      {:ok, snapshot, token} ->
        at = if is_binary(snapshot["continue_from"]), do: snapshot["continue_from"]
        people = if at, do: List.wrap(snapshot["pending"]), else: []
        pass(connect, key, token, at, people, Keyword.get(opts, :max_calls, @max_calls))

      other ->
        other
    end
  end

  defp claim(key, connect_id) do
    now = now()

    CasRecord.update(key, fn current ->
      current =
        current ||
          %{
            "connect_id" => connect_id,
            "provider" => @provider,
            "people" => [],
            "complete" => false,
            "synced_at" => nil
          }

      if claimed?(current, now),
        do: {:error, :busy},
        else: Map.put(current, "sync_started_at", now)
    end)
    |> case do
      {:ok, snapshot} -> {:ok, snapshot, now}
      {:error, :busy} -> :busy
      {:error, _reason} = error -> error
    end
  end

  defp claimed?(%{"sync_started_at" => at}, now) when is_integer(at), do: now - at < @lease_ms
  defp claimed?(_snapshot, _now), do: false

  defp pass(_connect, key, token, at, people, calls) when calls <= 0,
    do: finish(key, token, progress(people, at, nil), :incomplete)

  defp pass(connect, key, token, at, people, calls) do
    case Directory.list(connect, at) do
      {:ok, %{"complete" => true} = result} ->
        people = merge(people, result["users"])

        if length(people) > @max_people,
          do: finish(key, token, progress([], nil, @too_many), {:error, @too_many}),
          else: finish(key, token, whole(people), :ok)

      {:ok, %{"continue_from" => next} = result} when is_binary(next) ->
        people = merge(people, result["users"])

        cond do
          length(people) > @max_people ->
            finish(key, token, progress([], nil, @too_many), {:error, @too_many})

          result["error"] ->
            error = text(result["error"])
            finish(key, token, progress(people, next, error), {:error, error})

          true ->
            case commit(key, token, progress(people, next, nil)) do
              {:ok, token} -> pass(connect, key, token, next, people, calls - 1)
              error -> error
            end
        end

      {:ok, result} ->
        again(connect, key, token, at, people, calls, text(result["error"]))

      {:error, reason} ->
        again(connect, key, token, at, people, calls, text(reason))
    end
  end

  # A data range that changed, or a position no longer valid, starts the run
  # again from the beginning. Any other failure ends the run and keeps where
  # it stood, for the next run to try again.
  defp again(connect, key, token, at, people, calls, error) do
    if at != nil and Directory.restart?(error),
      do: pass(connect, key, token, nil, [], calls - 1),
      else: finish(key, token, progress(people, at, error), {:error, error})
  end

  defp whole(people) do
    %{
      "people" => people,
      "complete" => true,
      "synced_at" => now(),
      "pending" => [],
      "continue_from" => nil,
      "error" => nil
    }
  end

  defp progress(people, at, error) do
    %{
      "complete" => false,
      "pending" => if(at, do: people, else: []),
      "continue_from" => at,
      "error" => error
    }
  end

  # Stores a call's progress and renews the claim.
  defp commit(key, token, fields) do
    claim = now()

    case write(key, token, fields, claim) do
      {:ok, _snapshot} -> {:ok, claim}
      {:error, _reason} = error -> error
    end
  end

  # Stores the run's outcome and frees the claim.
  defp finish(key, token, fields, outcome) do
    case write(key, token, Map.put(fields, "run_at", now()), nil) do
      {:ok, _snapshot} -> outcome
      {:error, _reason} = error -> error
    end
  end

  # Writes only while this run holds the claim.
  defp write(key, token, fields, claim) do
    CasRecord.update(
      key,
      fn
        %{"sync_started_at" => ^token} = current ->
          current |> Map.merge(fields) |> Map.put("sync_started_at", claim)

        _other ->
          {:error, :claim_lost}
      end,
      create: false
    )
  end

  # One entry per open_id, in listing order, with every department any call
  # found the person in.
  defp merge(people, users) do
    {order, by_id} =
      (people ++ List.wrap(users))
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({[], %{}}, &add(&2, str(&1["open_id"]), &1))

    order |> Enum.reverse() |> Enum.map(&by_id[&1])
  end

  defp add(acc, "", _person), do: acc

  defp add({order, by_id}, id, person) do
    case by_id do
      %{^id => known} -> {order, Map.put(by_id, id, joined(known, person))}
      _new -> {[id | order], Map.put(by_id, id, person)}
    end
  end

  defp joined(known, person) do
    departments =
      Enum.uniq(List.wrap(known["departments"]) ++ List.wrap(person["departments"]))

    Map.put(known, "departments", departments)
  end

  @doc false
  # Called when the connect is retired.
  def delete(connect_id) when is_binary(connect_id) and connect_id != "" do
    case S3.delete(Keys.ctl_im_lark_directory(connect_id)) do
      {:error, reason} -> Logger.debug("lark directory copy not deleted: #{inspect(reason)}")
      _deleted -> :ok
    end

    :ok
  end

  def delete(_connect_id), do: :ok

  defp text(nil), do: "The Lark Contacts data range could not be read."
  defp text(error) when is_binary(error), do: error
  defp text(error), do: inspect(error)

  defp num(value) when is_integer(value), do: value
  defp num(_value), do: 0

  defp now, do: SystemsClock.system_time(:millisecond)
end
