defmodule SalixEnv.ClusterNodes do
  @moduledoc """
  Resolves a persisted node identity only against the local node and currently
  connected peers.

  Persisted or remote strings are never converted to atoms. Unknown and stale
  node names fail closed so untrusted node churn cannot grow the VM atom table.
  """

  @spec find(atom() | String.t()) :: node() | nil
  def find(candidate) when is_atom(candidate) do
    Enum.find(known_nodes(), &(&1 == candidate))
  end

  def find(candidate) when is_binary(candidate) do
    Enum.find(known_nodes(), &(Atom.to_string(&1) == candidate))
  end

  def find(_candidate), do: nil

  defp known_nodes, do: [node() | Node.list()]
end
