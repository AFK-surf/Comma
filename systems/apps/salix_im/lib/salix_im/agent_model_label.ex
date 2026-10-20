defmodule SalixIM.AgentModelLabel do
  @moduledoc """
  Best-effort display label for one Task worker.

  Reads the same canonical control records `SalixIM.GroupDirectory` exposes.
  A Task Session with its own catalog or platform choice displays it;
  otherwise Workers display the model they chose (`model`), or the platform
  model's name when they follow it. A Worker bound to a station
  (`SalixAgent.StationBinding`) displays `runtime · model`: the Task
  Session's runtime choice, then the binding's model. Without one, the
  station runs its runtime's default, which Salix does not know in advance.

  Resolution is read-only and never fails a caller — a missing agent or label
  field yields `""`.
  """

  alias SalixIM.GroupDirectory
  alias SalixStore.{Keys, S3}

  @max_label_length 80
  @own_login_runtimes ~w(codex claude)

  @doc """
  `session_model` is the Task Session's own model choice
  (`SalixAgent.ModelChoice`), kept on the Worker participant's payload.
  """
  @spec resolve(term(), term()) :: String.t()
  def resolve(agent_id, session_model \\ nil) do
    with agent_id when agent_id != "" <- trim(agent_id),
         {:ok, agent} <- GroupDirectory.get_agent(agent_id) do
      agent
      |> label(agent["station_binding"], session_model)
      |> trim()
      |> String.slice(0, @max_label_length)
    else
      _ -> ""
    end
  end

  defp label(
         _agent,
         %{"runs_on" => %{}, "model" => %{"provider" => provider} = model},
         session_model
       ) do
    provider = trim(provider)

    runtime_label(provider, [
      fn -> runtime_choice_model(session_model, provider) end,
      fn -> trim(model["model"]) end
    ])
  end

  # A Task Session inside Salix runs its own choice: the Router's, or the
  # Group's default Task model (`SalixAgent.TaskModel`).
  defp label(_agent, _binding, %{"kind" => "catalog", "model" => model}) when is_binary(model),
    do: trim(model)

  defp label(_agent, _binding, %{"kind" => "platform"}), do: platform_name()

  defp label(%{"model" => %{"kind" => kind, "model" => model}}, _binding, _session_model)
       when kind in ["catalog", "runtime"],
       do: trim(model)

  defp label(_agent, _binding, _session_model), do: platform_name()

  defp runtime_label("", _models), do: ""

  defp runtime_label(provider, models) do
    case Enum.find_value(models, &nonblank(&1.())) do
      nil when provider in @own_login_runtimes -> provider <> " · runtime default"
      nil -> provider
      model -> provider <> " · " <> model
    end
  end

  defp runtime_choice_model(%{"kind" => "runtime", "provider" => provider} = choice, provider),
    do: trim(choice["model"])

  defp runtime_choice_model(_choice, _provider), do: ""

  # The members' name of the platform model (`SalixAgent.PlatformModels.name/0`),
  # read without a production dependency from salix_im to salix_agent.
  defp platform_name do
    with {:ok, %{body: body}} <- S3.get(Keys.ctl_system_platform_models()),
         {:ok, %{"name" => name}} when is_binary(name) <- Jason.decode(body) do
      name
    else
      _ -> "Comma"
    end
  end

  defp nonblank(""), do: nil
  defp nonblank(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
