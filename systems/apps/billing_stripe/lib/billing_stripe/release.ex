defmodule BillingStripe.Release do
  @moduledoc "Release-time Stripe billing catalog tasks."

  require Logger

  @app :billing_stripe

  @doc "Sync a pricing catalog to Stripe and persist provider price ids."
  @spec sync_catalog(map(), keyword()) :: [map()]
  def sync_catalog(catalog, opts \\ []) when is_map(catalog) do
    prepare_apps()

    for repo <- repos() do
      case sync_repo_with_retries(repo, catalog, opts) do
        {:ok, summary} -> summary
        {:error, reason} -> raise "failed to sync Stripe billing catalog: #{inspect(reason)}"
      end
    end
  end

  @doc "Create or converge the Comma portal through an explicit ops command."
  def sync_portal(catalog, opts \\ []) do
    prepare_apps()

    for repo <- repos() do
      result = sync_repo_with_retries(repo, catalog, Keyword.put(opts, :portal_sync, true))

      case result do
        {:ok, summary} -> summary
        {:error, reason} -> raise "failed to sync Comma portal: #{inspect(reason)}"
      end
    end
  end

  defp sync_repo_with_retries(repo, catalog, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 1)
    sync_repo_attempt(repo, catalog, opts, 1, max_attempts)
  end

  defp sync_repo_attempt(repo, catalog, opts, attempt, max_attempts) do
    result =
      Ecto.Migrator.with_repo(repo, fn started_repo ->
        if opts[:portal_sync],
          do: BillingStripe.PortalSync.sync(catalog, Keyword.put(opts, :repo, started_repo)),
          else: sync_repo(started_repo, catalog, opts)
      end)

    case result do
      {:ok, {:ok, summary}, _started} ->
        {:ok, summary}

      {:ok, {:error, reason}, _started} when attempt < max_attempts ->
        if transient?(reason) do
          Process.sleep(attempt * 1_000)
          sync_repo_attempt(repo, catalog, opts, attempt + 1, max_attempts)
        else
          {:error, reason}
        end

      {:ok, {:error, reason}, _started} ->
        {:error, reason}

      {:error, reason} when attempt < max_attempts ->
        if transient?(reason) do
          Process.sleep(attempt * 1_000)
          sync_repo_attempt(repo, catalog, opts, attempt + 1, max_attempts)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_repo(repo, catalog, opts) do
    if Keyword.get(opts, :require_provider, false) and not Keyword.get(opts, :dry_run, false) do
      BillingCore.BillingJSONRepair.run(repo)
    end

    opts = Keyword.put(opts, :repo, repo)

    case BillingStripe.sync_prices(catalog, opts) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, :stripe_not_configured} ->
        if Keyword.get(opts, :require_provider, false) do
          {:error, :stripe_not_configured}
        else
          sync_local_catalog_without_stripe(catalog, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transient?({:http, status}) when status in [408, 409, 425, 429], do: true
  defp transient?({:http, status}) when is_integer(status) and status >= 500, do: true
  defp transient?(:timeout), do: true
  defp transient?(:econnrefused), do: true
  defp transient?(%Stripe.Error{source: :network}), do: true

  defp transient?(%Stripe.Error{source: :stripe, code: code, extra: extra}) do
    transient?({:http, Map.get(extra || %{}, :http_status)}) or
      code in [
        :api_connection_error,
        :api_error,
        :conflict,
        :rate_limit_error,
        :server_error,
        :too_many_requests
      ]
  end

  defp transient?({:error, reason}), do: transient?(reason)
  defp transient?(_reason), do: false

  defp sync_local_catalog_without_stripe(catalog, opts) do
    Logger.warning("Skipping Stripe price sync because billing_stripe is not configured")

    case BillingCommerce.sync_local_pricing_catalog(catalog, opts) do
      {:ok, local} ->
        {:ok,
         %{
           local: local,
           provider: "stripe",
           provider_prices: [],
           provider_sync: :skipped,
           reason: :stripe_not_configured
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repos do
    Application.get_env(:billing_core, :ecto_repos, [])
  end

  defp prepare_apps do
    Application.load(:billing_core)
    Application.load(:billing_commerce)
    Application.load(@app)

    # Release eval commands load subsystem applications without starting them.
    # Start only Stripe's transport boundary so Hackney creates its request pool.
    {:ok, _started} = Application.ensure_all_started(:stripity_stripe)
  end
end
