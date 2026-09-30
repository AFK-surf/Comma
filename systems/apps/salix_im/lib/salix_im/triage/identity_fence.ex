defmodule SalixIM.Triage.IdentityFenceHandle do
  @moduledoc "Opaque, process-local capability minted by a winning Triage Runtime."

  @enforce_keys [:runtime, :capability]
  defstruct [:runtime, :capability]

  @opaque t :: %__MODULE__{runtime: pid(), capability: reference()}
end

defmodule SalixIM.Triage.IdentityFence do
  @moduledoc """
  Process-capability interface for one Runtime-owned identity fence.

  Consumers can spend only the opaque handle operations defined here. They do
  not depend on Runtime's implementation module or gain access to its process
  state, durable keys, timers, or terminal policy.
  """

  alias SalixIM.Triage.IdentityFenceHandle

  def claim_observation(%IdentityFenceHandle{runtime: runtime} = handle, claim)
      when is_map(claim),
      do: GenServer.call(runtime, {:identity_fence, handle, :claim, claim})

  def claim_observation(_handle, _claim), do: {:error, :identity_fence_denied}

  def mark_transport_started(%IdentityFenceHandle{runtime: runtime} = handle),
    do: GenServer.call(runtime, {:identity_fence, handle, :mark_transport, nil})

  def mark_transport_started(_handle), do: {:error, :identity_fence_denied}

  def commit_transport(%IdentityFenceHandle{runtime: runtime} = handle, result)
      when is_map(result),
      do: GenServer.call(runtime, {:identity_fence, handle, :commit_transport, result})

  def commit_transport(_handle, _result), do: {:error, :identity_fence_denied}

  def bind_projection(
        %IdentityFenceHandle{runtime: runtime} = handle,
        private_projection,
        context_sha256
      )
      when is_map(private_projection) and is_binary(context_sha256),
      do:
        GenServer.call(
          runtime,
          {:identity_fence, handle, :bind_projection,
           %{private_projection: private_projection, context_sha256: context_sha256}}
        )

  def bind_projection(_handle, _private_projection, _context_sha256),
    do: {:error, :identity_fence_denied}

  def bind_snapshot(%IdentityFenceHandle{runtime: runtime} = handle, model_input)
      when is_map(model_input),
      do: GenServer.call(runtime, {:identity_fence, handle, :bind_snapshot, model_input})

  def bind_snapshot(_handle, _model_input), do: {:error, :identity_fence_denied}

  def authorize_model(%IdentityFenceHandle{runtime: runtime} = handle),
    do: GenServer.call(runtime, {:identity_model_authorize, handle})

  def authorize_model(_handle), do: {:error, :identity_fence_denied}

  def model_runtime(%IdentityFenceHandle{runtime: runtime} = handle),
    do: GenServer.call(runtime, {:identity_model_runtime, handle})

  def model_runtime(_handle), do: {:error, :identity_fence_denied}

  def validate_model_decision(
        %IdentityFenceHandle{runtime: runtime} = handle,
        decision
      )
      when is_map(decision),
      do: GenServer.call(runtime, {:identity_model_decision_validate, handle, decision})

  def validate_model_decision(_handle, _decision), do: {:error, :identity_fence_denied}

  def authorize_read_tool(%IdentityFenceHandle{runtime: runtime} = handle),
    do: GenServer.call(runtime, {:identity_read_tool_authorize, handle})

  def authorize_read_tool(_handle), do: {:error, :identity_fence_denied}

  def commit_read_tool(%IdentityFenceHandle{runtime: runtime} = handle, receipt)
      when is_map(receipt),
      do: GenServer.call(runtime, {:identity_read_tool_commit, handle, receipt})

  def commit_read_tool(_handle, _receipt), do: {:error, :identity_fence_denied}
end
