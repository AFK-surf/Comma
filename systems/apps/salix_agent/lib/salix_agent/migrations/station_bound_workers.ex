defmodule SalixAgent.Migrations.StationBoundWorkers do
  @moduledoc """
  Bind every External Runtime Worker to a station (`SalixAgent.StationBinding`),
  so its Tasks run there as station Tasks and no Worker needs an External
  Session any more.

    * A Worker on a connected device runtime (`runtime_config.kind` external or
      connected_runtime) is bound to that device's station
      (`{kind: station, device_id}`; the Group's Cloud VM device becomes
      `{kind: cloud_vm}`).
    * A Worker on a Compute Workload is bound to the Group's Cloud VM
      (`{kind: cloud_vm}`), which goes on the Agent VMM Host of the Group's
      Project where it has one. The binding is all a Worker needs to use the
      Group's Cloud VM (`SalixAgent.StationBinding.cloud_vm?/1`): the pass
      leaves the Worker's `vm` as it is and asks no VM provider anything, so
      it runs the same in a release job (where none is wired) as on a node.
    * The runtime is the Worker's provider when it is codex or claude. The
      model is its configured model (the runtime binding's, else the Agent's
      runtime choice of that provider) when the catalog knows it for that
      runtime; otherwise the binding names none and the station runs its
      default.
    * A Worker on a Pi or Kimi runtime has no station runtime: it is archived
      with `archive_reason`, not deleted, and can be unarchived.

  Run during a rolling release, like `SalixAgent.Migrations.TemplatePinChoices`:
  each page reads at most 100 canonical Agent records; `runtime_config` stays,
  so processes of the previous release run the Worker as before until they are
  replaced; conditional writes skip a record changed or deleted after the read,
  and a Worker already bound is left as it is, so a pass run again changes
  nothing. A bound Worker is an internal Worker: its earlier External Sessions
  are read-only history (`SalixAgent.RetiredSessions`), and their stored
  records stay. No Agent, Session or stored object is deleted.
  """

  require Logger

  alias SalixAgent.{AgentControl, ModelChoice}
  alias SalixStore.{Keys, RuntimeIds, S3}

  @providers ~w(codex claude)

  def run, do: page(nil, %{station: 0, cloud_vm: 0, archived: 0})

  defp page(cursor, counts) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_agents_prefix(), max_keys: 100, continuation_token: cursor),
         {:ok, counts} <-
           Enum.reduce_while(objects, {:ok, counts}, fn object, {:ok, counts} ->
             case migrate_object(object.key) do
               {:ok, nil} -> {:cont, {:ok, counts}}
               {:ok, kind} -> {:cont, {:ok, Map.update!(counts, kind, &(&1 + 1))}}
               error -> {:halt, error}
             end
           end) do
      if next, do: page(next, counts), else: {:ok, counts}
    end
  end

  defp migrate_object(key) do
    with {:ok, %{body: body, etag: etag}} <- S3.get(key),
         {:ok, agent} <- Jason.decode(body) do
      case plan(agent) do
        nil ->
          {:ok, nil}

        {:archive, provider} ->
          archive(agent, provider)

        {kind, binding} ->
          bound = Map.put(agent, "station_binding", binding)

          case S3.put(key, Jason.encode!(bound), if_match: etag) do
            {:ok, _} ->
              {:ok, kind}

            {:error, :precondition_failed} ->
              {:ok, nil}

            {:error, :not_found} ->
              {:ok, nil}

            error ->
              error
          end
      end
    else
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp plan(%{"station_binding" => %{}}), do: nil
  defp plan(%{"permanent_archive" => true}), do: nil

  defp plan(%{"role" => "worker", "runtime_config" => %{"kind" => kind} = config} = agent)
       when kind in ~w(external connected_runtime) do
    device_id = config["device_id"]

    cond do
      config["provider"] not in @providers ->
        archive_plan(agent, config["provider"])

      not is_binary(device_id) or device_id == "" ->
        nil

      device_id == RuntimeIds.cloud_vm_device_id(agent["group_id"]) ->
        {:cloud_vm, binding(agent, %{"kind" => "cloud_vm"}, config["provider"], config)}

      true ->
        {:station,
         binding(
           agent,
           %{"kind" => "station", "device_id" => device_id},
           config["provider"],
           config
         )}
    end
  end

  defp plan(
         %{
           "role" => "worker",
           "runtime_config" =>
             %{"kind" => "compute_workload", "workload_id" => workload_id} = config
         } = agent
       )
       when is_binary(workload_id) and workload_id != "" do
    spec = config["runtime_spec"] || %{}

    if spec["provider"] in @providers,
      do: {:cloud_vm, binding(agent, %{"kind" => "cloud_vm"}, spec["provider"], spec)},
      else: archive_plan(agent, spec["provider"])
  end

  defp plan(_agent), do: nil

  defp archive_plan(%{"archived_at" => _}, _provider), do: nil
  defp archive_plan(_agent, provider), do: {:archive, provider}

  defp binding(agent, runs_on, provider, settings) do
    %{
      "runs_on" => runs_on,
      "model" => model(agent, provider, settings),
      "binding_revision" => 1
    }
  end

  # The Worker's configured model when the catalog knows it for the runtime,
  # with its effort when the model takes it; else none (the station default).
  defp model(agent, provider, settings) do
    agent_choice =
      case agent["model"] do
        %{"kind" => "runtime", "provider" => ^provider} = choice -> choice
        _ -> %{}
      end

    configured = settings["model"] || agent_choice["model"]

    effort =
      if settings["model"],
        do: settings["reasoning_effort"],
        else: agent_choice["reasoning_effort"]

    base = %{"kind" => "runtime", "provider" => provider}

    with true <- is_binary(configured) and configured != "",
         choice = Map.put(base, "model", configured),
         {:ok, value} <- choose(choice, effort, agent["tenant_id"]) do
      value
    else
      _ ->
        if is_binary(configured) and configured != "",
          do:
            Logger.info(
              "station binding keeps the station default model: agent=#{agent["agent_id"]} provider=#{provider}"
            )

        base
    end
  end

  defp choose(choice, effort, tenant_id) when is_binary(effort) and effort != "" do
    case ModelChoice.choose(Map.put(choice, "reasoning_effort", effort), tenant_id) do
      {:ok, _} = ok -> ok
      {:error, _} -> ModelChoice.choose(choice, tenant_id)
    end
  end

  defp choose(choice, _effort, tenant_id), do: ModelChoice.choose(choice, tenant_id)

  defp archive(agent, provider) do
    reason = "external runtime retired: #{provider || "unknown"} has no station runtime"

    case AgentControl.archive_retired_runtime(agent["agent_id"], reason) do
      {:ok, _} -> {:ok, :archived}
      {:error, :not_found} -> {:ok, nil}
      {:error, :agent_permanently_archived} -> {:ok, nil}
      error -> error
    end
  end
end
