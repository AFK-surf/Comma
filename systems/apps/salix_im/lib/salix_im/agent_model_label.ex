defmodule SalixIM.AgentModelLabel do
  @moduledoc """
  Best-effort display label for one Task worker.

  Reads the same canonical control records `SalixIM.GroupDirectory` exposes:
  external and compute workers display their runtime provider, while internal
  workers display their template's `model`.
  Resolution is read-only and never fails a caller — a missing agent, template,
  or label field yields `""`. External workers never use the internal template
  model, even when their runtime has an explicit model.
  """

  alias SalixIM.GroupDirectory
  alias SalixStore.{Ids, Keys, S3}

  @max_label_length 80

  @spec resolve(term()) :: String.t()
  def resolve(agent_id) do
    with agent_id when agent_id != "" <- trim(agent_id),
         {:ok, agent} <- GroupDirectory.get_agent(agent_id) do
      agent |> label(agent["runtime_config"]) |> trim() |> String.slice(0, @max_label_length)
    else
      _ -> ""
    end
  end

  defp label(_agent, %{"kind" => kind} = runtime)
       when kind in ["external", "connected_runtime"] do
    trim(runtime["provider"])
  end

  defp label(_agent, %{"kind" => "compute_workload"} = runtime) do
    spec = if is_map(runtime["runtime_spec"]), do: runtime["runtime_spec"], else: %{}
    trim(spec["provider"])
  end

  defp label(agent, _runtime), do: template_model(agent)

  defp template_model(%{"template_id" => template_id} = agent) do
    with template_id when template_id != "" <- trim(template_id),
         {:ok, key, owner} <- template_key(template_id, agent["tenant_id"]),
         {:ok, %{body: body}} <- S3.get(key),
         {:ok, %{"template_id" => ^template_id, "model" => model} = template} <-
           Jason.decode(body),
         true <- template["tenant_id"] == owner,
         model when model != "" <- trim(model) do
      model
    else
      _ -> ""
    end
  end

  defp template_model(_agent), do: ""

  # Match Templates' exact-key and owner rules without a production dependency
  # from salix_im to salix_agent. Only the display label leaves this reader.
  defp template_key("ptm1_" <> _ = id, tenant_id) do
    if Ids.valid_private_template_id?(id) and Ids.valid_tenant_id?(tenant_id),
      do: {:ok, Keys.ctl_private_template(tenant_id, id), tenant_id},
      else: {:error, :not_found}
  end

  defp template_key(id, _tenant_id), do: {:ok, Keys.ctl_template(id), nil}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
