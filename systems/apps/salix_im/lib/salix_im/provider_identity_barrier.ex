defmodule SalixIM.ProviderIdentityBarrier do
  @moduledoc """
  Test-only pause points inside multi-object storage sequences.

  Production is a no-op (one config read on cold paths only). A test
  installs a function per barrier name; the sequence blocks inside that
  function, letting the test complete a competing PUBLIC operation and
  then release it — so cross-object interleavings are constructed
  deterministically instead of relying on timing.

      Application.put_env(:salix_im, :provider_identity_barrier, %{
        identity_fallback_settle: fn -> send(test, :hit) and receive(do: (:go -> :ok)) end
      })
  """

  @spec hit(atom()) :: :ok
  def hit(name) do
    case Application.get_env(:salix_im, :provider_identity_barrier) do
      nil ->
        :ok

      barriers when is_map(barriers) ->
        case Map.get(barriers, name) do
          fun when is_function(fun, 0) ->
            fun.()
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
