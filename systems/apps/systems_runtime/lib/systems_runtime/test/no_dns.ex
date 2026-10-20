defmodule SystemsRuntime.Test.NoDNS do
  @moduledoc """
  A resolver for tests, in place of `:inet`, that answers this machine's names
  and no others: a host name outside this machine is `{:error, :nxdomain}`, as
  if it did not exist, without a lookup (docs/testing.md#no-real-network).

      config :salix_mcp, resolver: SystemsRuntime.Test.NoDNS
  """

  @doc "As `:inet.getaddrs/2`."
  def getaddrs(host, family) do
    if SystemsRuntime.NetworkGuard.local?(host),
      do: :inet.getaddrs(host, family),
      else: {:error, :nxdomain}
  end
end
