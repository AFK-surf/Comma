defmodule SalixStore.AgentVMMFixtures do
  @moduledoc false
  alias SalixStore.{AgentVMM.Registration, Repo}

  # Transport and Compute tests start with an already-authorized Registration.
  # Product authorization/claim tests use AgentVMMRegistrations instead.
  def registration(attrs) do
    now = SystemsClock.utc_now()
    enabled = Map.get(attrs, :desired_enabled, false)
    credential = Map.get(attrs, :credential)

    row = %{
      id: attrs.id,
      tenant_id: attrs.tenant_id,
      group_id: attrs.group_id,
      device_id: attrs.device_id,
      revision: 1,
      policy_revision: 1,
      desired_enabled: enabled,
      status:
        cond do
          not enabled -> "disabled"
          is_binary(credential) -> "ready"
          true -> "enrolling"
        end,
      credential_hash: if(is_binary(credential), do: :crypto.hash(:sha256, credential)),
      authorization_expires_at: DateTime.add(now, 7 * 86_400, :second),
      created_at: now,
      updated_at: now
    }

    case Repo.insert_all(Registration, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Repo.get!(Registration, attrs.id)}
      {0, _} -> {:error, :already_exists}
    end
  end
end
