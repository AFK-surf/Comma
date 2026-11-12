defmodule SalixAgent.PlatformBalance do
  @moduledoc """
  The prepaid balance of the platform's DeepSeek accounts, published as the
  gauge `salix.llm.platform_account.balance{provider, kind}` (`kind` is the
  currency, `cny` or `usd`), so operators hear of a low balance before the
  account runs out (`platform_model_account_low_balance`). An account that has
  run out is the `platform_model_account_failed` alert's.

  Every 5 minutes each node reads `GET /user/balance` of every enabled
  platform API key that DeepSeek serves (at most the bounded page of
  `SalixAgent.SubscriptionStore.usable_api_keys/1`) and publishes, per
  currency, the lowest balance among them. A failed read publishes nothing:
  the gauge keeps its last value. Other providers expose no balance to an API
  key and are not read.

  Settings of `:salix_agent, :platform_balance` (`req_options`) are for tests.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixAgent.{AccountPool, LLMProvider}
  alias SalixAgent.SubscriptionStore, as: Store

  @interval_ms 300_000
  @currencies ~w(cny usd)

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, schedule()}

  @impl true
  def handle_info(:poll, _state) do
    emit()
    {:noreply, schedule()}
  end

  defp schedule, do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, @interval_ms)

  @doc """
  Read the balances and publish the lowest per provider and currency.
  Returns the published `%{{provider, currency} => balance}`.
  """
  @spec emit() :: %{{String.t(), String.t()} => float()}
  def emit do
    tenant = AccountPool.platform_tenant()

    lowest =
      case Store.usable_api_keys(tenant) do
        {:ok, records} ->
          for record <- records,
              url when is_binary(url) <- [balance_url(record)],
              {:ok, key} <- [api_key(tenant, record)],
              {currency, balance} <- read(url, key),
              reduce: %{} do
            acc -> Map.update(acc, {"deepseek", currency}, balance, &min(&1, balance))
          end

        _ ->
          %{}
      end

    for {{provider, currency}, balance} <- lowest do
      SystemsRuntime.Telemetry.execute(
        [:salix, :llm, :platform_account_balance],
        %{balance: balance},
        %{provider: provider, kind: currency}
      )
    end

    lowest
  rescue
    exception ->
      Logger.warning("platform balance skipped", exception: inspect(exception.__struct__))
      %{}
  end

  # DeepSeek answers the balance at its API host, whatever path the Profile's
  # endpoint carries (`https://api.deepseek.com` or `.../v1`).
  defp balance_url(record) do
    endpoints = Map.values(record["endpoints"] || %{})

    if record["source"] == "deepseek" or
         Enum.any?(endpoints, &(LLMProvider.infer_provider(%{base_url: &1}) == "deepseek")) do
      Enum.find_value(endpoints, fn endpoint ->
        case URI.parse(to_string(endpoint)) do
          %URI{scheme: scheme, host: host} = uri
          when scheme in ["http", "https"] and is_binary(host) ->
            URI.to_string(%URI{uri | path: "/user/balance", query: nil, fragment: nil})

          _ ->
            nil
        end
      end)
    end
  end

  defp api_key(tenant, record) do
    case Store.open(tenant, record["id"], record["credentials"]) do
      {:ok, %{"api_key" => key}} when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  defp read(url, key) do
    options =
      [
        headers: [{"authorization", "Bearer " <> key}, {"accept", "application/json"}],
        retry: false,
        redirect: false,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000]
      ]
      |> Keyword.merge(
        SystemsRuntime.get_env(:salix_agent, :platform_balance, [])[:req_options] || []
      )

    case Req.get(url, options) do
      {:ok, %{status: 200, body: %{"balance_infos" => infos}}} when is_list(infos) ->
        for %{"currency" => currency, "total_balance" => total} <- infos,
            code when code in @currencies <- [String.downcase(to_string(currency))],
            {balance, ""} <- [Float.parse(to_string(total))],
            do: {code, balance}

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
