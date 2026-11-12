defmodule SalixStore.AgentVMMRecovery do
  @moduledoc "Fixed registration recovery proof purpose, wire format, and two-minute lifetime."

  @purpose "agent-vmm/credential-replace/1"
  @ttl 120
  @fields ~w(audience subject session_id controller_binding environment_id registration_id candidate_credential_hash nonce)

  def purpose, do: @purpose
  def ttl, do: @ttl

  def wire(challenge) when is_map(challenge) do
    values = Enum.map(@fields, &Map.get(challenge, &1))

    if challenge["purpose"] == @purpose and
         Enum.all?(Enum.zip(@fields, values), fn {field, value} ->
           limit = if field == "controller_binding", do: 1500, else: 500
           is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
         end) and
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
