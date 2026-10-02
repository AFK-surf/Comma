defmodule SalixStore.AgentVMMRecovery do
  @moduledoc "Fixed Comma recovery proof purpose, wire format, and two-minute lifetime."

  @purpose "agent-vmm/comma-recovery/1"
  @ttl 120
  @fields ~w(audience subject session_id tenant_id group_id scope_key environment_id operation_id registration_id nonce)

  def purpose, do: @purpose
  def ttl, do: @ttl

  def wire(challenge) when is_map(challenge) do
    values = Enum.map(@fields, &Map.get(challenge, &1))

    if challenge["purpose"] == @purpose and
         Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..500 and String.valid?(&1))) and
         is_integer(challenge["revision"]) and challenge["revision"] > 0 and
         is_integer(challenge["expires_at"]) do
      {:ok,
       Enum.join(
         [@purpose] ++
           Enum.map(values, &Base.url_encode64(&1, padding: false)) ++
           [
             Integer.to_string(challenge["revision"]),
             Integer.to_string(challenge["expires_at"]),
             ""
           ],
         "\n"
       )}
    else
      {:error, :invalid_recovery_challenge}
    end
  end

  def wire(_), do: {:error, :invalid_recovery_challenge}
end
