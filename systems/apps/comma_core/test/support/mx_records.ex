defmodule Comma.TestSupport.MxRecords do
  @moduledoc """
  An MX resolver for tests (`config :comma_core, :mx_resolver`), in place of
  `:inet_res`: a domain's MX hosts are what the test bound with `put/1`
  (`SystemsRuntime.Test`), every other domain has none.
  """

  @doc "Binds this test's MX hosts, a map of domain to host names."
  def put(records) when is_map(records) do
    SystemsRuntime.Test.put_env(:comma_core, :mx_resolver, __MODULE__)
    SystemsRuntime.Test.put_env(:comma_core, :mx_test_records, records)
  end

  @doc "As `:inet_res.lookup/4`, for MX records."
  def lookup(name, :in, :mx, _opts) do
    :comma_core
    |> SystemsRuntime.get_env(:mx_test_records, %{})
    |> Map.get(to_string(name), [])
    |> Enum.with_index(fn host, i -> {10 * (i + 1), String.to_charlist(host)} end)
  end
end
