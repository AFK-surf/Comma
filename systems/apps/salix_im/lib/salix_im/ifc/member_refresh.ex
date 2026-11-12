defmodule SalixIM.IFC.MemberRefresh do
  @moduledoc """
  Background member listings for `SalixIM.IFC.Projection`.

  A decision reads only Postgres, so whatever the provider knows reaches the
  store here: ingress and decisions name the conversations they touch, and
  each is read from its provider at most once per `Projection.ttl_ms/0` on
  this node. The pool is bounded; a listing that does not fit is skipped and
  asked for again by the next inbound or decision that names it.
  """

  require Logger

  alias SalixIM.IFC.Projection

  @table :salix_ifc_member_refresh
  @max_entries 50_000
  @task_supervisor SalixIM.IFCMemberRefreshTasks

  @doc false
  def create_table! do
    SystemsRuntime.ETS.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  @doc """
  Asks for one conversation's members in the background when its kind has a
  member set and this node has not read it within the bound.
  """
  @spec schedule(Projection.scope(), String.t(), map()) :: :ok
  def schedule(scope, scope_id, row) do
    if enabled?() and is_binary(scope_id) and scope_id != "" and
         not Projection.direct_scope_id?(scope_id) and Projection.needs_members?(row) and
         claim({scope.tenant_id, scope.group_id, scope.connect_id, scope_id}) do
      case SystemsRuntime.TaskSupervisor.start_child(@task_supervisor, fn ->
             Projection.refresh(scope, scope_id)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          release({scope.tenant_id, scope.group_id, scope.connect_id, scope_id})
          Logger.debug("ifc member refresh not started: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp enabled?, do: SystemsRuntime.get_env(:salix_im, :ifc_member_refresh, true) != false

  # One claim per conversation per bound. A full table claims nothing new,
  # which bounds memory and only delays a listing.
  defp claim(key) do
    now = SystemsClock.monotonic_time(:millisecond)

    ttl = Projection.ttl_ms()

    case SystemsRuntime.ETS.lookup(@table, key) do
      [{^key, claimed_at}] when now - claimed_at < ttl ->
        false

      found ->
        if found == [] and SystemsRuntime.ETS.info(@table, :size) >= @max_entries do
          false
        else
          SystemsRuntime.ETS.insert(@table, {key, now})
          true
        end
    end
  end

  defp release(key), do: SystemsRuntime.ETS.delete(@table, key)
end
