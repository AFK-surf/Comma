defmodule SystemsRuntime.Registry do
  @moduledoc """
  `Registry`: each function is the `Registry` function of the same name, and
  a name `{:via, SystemsRuntime.Registry, {registry, key}}` is the registry's.
  """

  @doc "A child spec, as `Registry.child_spec/1`."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a registry, as `Registry.start_link/1`."
  def start_link(opts), do: Registry.start_link(opts)

  @doc "As `Registry.register/3`."
  def register(registry, key, value), do: Registry.register(registry, key, value)

  @doc "As `Registry.unregister/2`."
  def unregister(registry, key), do: Registry.unregister(registry, key)

  @doc "As `Registry.lookup/2`."
  def lookup(registry, key), do: Registry.lookup(registry, key)

  @doc "As `Registry.select/2`."
  def select(registry, spec), do: Registry.select(registry, spec)

  @doc "As `Registry.count/1`."
  def count(registry), do: Registry.count(registry)

  @doc "As `Registry.keys/2`."
  def keys(registry, pid), do: Registry.keys(registry, pid)

  @doc "As `Registry.update_value/3`."
  def update_value(registry, key, fun), do: Registry.update_value(registry, key, fun)

  @doc "As `Registry.dispatch/4`: `fun` gets the entries of `key`."
  def dispatch(registry, key, fun, opts \\ []), do: Registry.dispatch(registry, key, fun, opts)

  ## `:via` names

  @doc false
  def register_name({registry, key}, pid), do: Registry.register_name({registry, key}, pid)

  @doc false
  def unregister_name({registry, key}), do: Registry.unregister_name({registry, key})

  @doc false
  def whereis_name({registry, key}), do: Registry.whereis_name({registry, key})

  @doc false
  def send({registry, key}, msg), do: Registry.send({registry, key}, msg)
end
