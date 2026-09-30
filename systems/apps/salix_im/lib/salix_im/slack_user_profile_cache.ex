defmodule SalixIM.SlackUserProfileCache do
  @moduledoc """
  Node-local cache of Slack user profiles resolved through `users.info`.

  Ingress reads the author's display name for every inbound message that
  carries none, and that one provider round trip sat in front of Router
  delivery. Display names change rarely, so a resolved profile is reused for
  `ttl_ms` per `{scope, user_id}`, where the scope is the Slack workspace (or
  the connect when the workspace is unknown). Only profiles with a name are
  cached; an empty or failed lookup is retried on the next message.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms :timer.minutes(10)

  # The table needs an owner that outlives the ingress tasks that fill it.
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    _ = table()
    {:ok, %{}}
  end

  @spec fetch(term(), String.t(), (-> map())) :: map()
  def fetch(scope, user_id, resolve) when is_function(resolve, 0) do
    key = {scope, user_id}
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:ok, profile} ->
        profile

      :miss ->
        profile = resolve.()
        if cacheable?(profile), do: store(key, profile, now)
        profile
    end
  end

  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    case Application.get_env(:salix_im, :slack_user_profile_cache_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @default_ttl_ms
    end
  end

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(table())
    :ok
  end

  defp store(key, profile, now) do
    case ttl_ms() do
      0 -> :ok
      ttl -> :ets.insert(table(), {key, profile, now + ttl})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cacheable?(profile) when is_map(profile) do
    Enum.any?(~w(user_display_name user_real_name user_name), fn field ->
      is_binary(profile[field]) and String.trim(profile[field]) != ""
    end)
  end

  defp cacheable?(_profile), do: false

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  # Without the owning process (a test that did not start the application
  # tree) the table lives with whoever created it; lookups still work and a
  # lost table simply means a miss.
  defp lookup(key, now) do
    case :ets.lookup(table(), key) do
      [{^key, profile, expires_at}] when expires_at > now -> {:ok, profile}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end
end
