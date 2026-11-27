defmodule SalixAgent.PlatformRouter do
  @moduledoc """
  The platform Router of a Tenant: a value on the Tenant, not an entity.

  The platform admin gives one Tenant a catalog model that platform API keys
  serve first for the Tenant's Routers: `%{"model" => id,
  "reasoning_effort" => effort | nil, "billing" => "record" | "deduct",
  "allow_paid" => boolean}`. `record` meters the calls and charges 0;
  `deduct` meters them and spends the organization's credits. `allow_paid`
  (default false) is the admin's option that puts the Tenant's API keys in
  the fallback.

  A Router uses it while its stored Model Choice carries the mark
  `"platform" => true` (`SalixAgent.ModelChoice`) and this record exists and
  names the same model. Then each request goes to the platform keys that
  serve the model first, then to the Tenant's subscriptions, and to its API
  keys only when the record's `allow_paid` is true (`SalixAgent.AccountPool`
  reads it at dispatch through `serving/2`). No Tenant write path stores the
  mark: only `apply/1` (the admin's save) and the creation of a new Router
  write it, and a Tenant admin who chooses another model drops it.

  Storage: the `platform_router` tenant config record (`SalixStore.TenantConfigs`).
  """

  alias SalixAgent.{AccountPool, AgentControl, ModelChoice, PlatformModels}
  alias SalixStore.{AgentPGStore, TenantConfigs, TenantProfiles}

  require Logger

  @name "platform_router"
  @billing ~w(record deduct)
  # `apply/1` reads at most this many pages of this many Agents.
  @page 200
  @max_pages 25

  @doc "The Tenant's platform Router, or `{:error, :not_found}`."
  @spec get(String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get(tenant) when is_binary(tenant) and tenant != "" do
    case TenantConfigs.get(tenant, @name) do
      {:ok, %{"value" => %{"model" => model} = value}} when is_binary(model) ->
        {:ok,
         value
         |> Map.take(~w(model reasoning_effort billing))
         |> Map.put("allow_paid", value["allow_paid"] == true)}

      _ ->
        {:error, :not_found}
    end
  end

  def get(_tenant), do: {:error, :not_found}

  @doc """
  Store the Tenant's platform Router. An enabled platform API key must serve
  the model, the effort must be one the model offers, and `billing` is
  `record` or `deduct`. `allow_paid` is true or false (or the form strings
  `"true"` / `"false"`; absent is false). Routers keep their choice until
  `apply/1`.
  """
  @spec put(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(tenant, %{} = attrs) when is_binary(tenant) do
    model = attrs["model"]
    effort = blank_to_nil(attrs["reasoning_effort"])
    allow_paid = allow_paid(attrs["allow_paid"])

    with true <- SalixStore.Ids.valid_tenant_id?(tenant) || {:error, :not_found},
         true <-
           (tenant != AccountPool.platform_tenant() and is_binary(model) and model != "" and
              attrs["billing"] in @billing and is_boolean(allow_paid)) ||
             {:error, :invalid_platform_router},
         {:ok, info} <- PlatformModels.model_info(model),
         true <-
           (is_nil(effort) or effort in (info["efforts"] || [])) ||
             {:error, :invalid_platform_router},
         {:ok, _key, _request, _protocol} <- AccountPool.platform_key(model) do
      value =
        %{
          "model" => model,
          "reasoning_effort" => effort,
          "billing" => attrs["billing"],
          "allow_paid" => allow_paid
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, _record} =
        TenantConfigs.put(%{
          "tenant_id" => tenant,
          "name" => @name,
          "value" => value,
          "updated_at" => SystemsClock.system_time(:second)
        })

      {:ok, value}
    end
  end

  def put(_tenant, _attrs), do: {:error, :invalid_platform_router}

  @doc """
  Remove the Tenant's platform Router. Marked Routers keep their choice and
  are then served by the Tenant's subscriptions, and its API keys only when
  the stored choice allows pay-per-use.
  """
  @spec delete(String.t()) :: :ok
  def delete(tenant) when is_binary(tenant), do: TenantConfigs.delete(tenant, @name)

  @doc """
  The marked Model Choice of the Tenant's platform Router, or nil. It carries
  `"allow_paid" => true` only when the record allows pay-per-use.
  """
  @spec choice(String.t() | nil) :: map() | nil
  def choice(tenant) do
    case get(tenant) do
      {:ok, router} ->
        %{
          "kind" => "catalog",
          "model" => router["model"],
          "reasoning_effort" => router["reasoning_effort"],
          "platform" => true,
          "allow_paid" => if(router["allow_paid"], do: true)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  The Tenant's platform Router as its organization may see it:
  `{:ok, %{"model" => id, "label" => display name}}`, or `{:ok, nil}` when it
  has none. It names no billing, no pay-per-use option and no platform
  Profile.
  """
  @spec public(String.t() | nil) :: {:ok, map() | nil}
  def public(tenant) do
    case choice(tenant) do
      nil ->
        {:ok, nil}

      choice ->
        label =
          case ModelChoice.public(choice, tenant) do
            {:ok, %{"model_display_name" => name}} when is_binary(name) and name != "" -> name
            _unknown -> choice["model"]
          end

        {:ok, %{"model" => choice["model"], "label" => label}}
    end
  end

  @doc """
  How the platform Router that serves `model` for the Tenant serves it:
  `%{"billing" => billing, "allow_paid" => boolean}`, or nil when the Tenant
  has none or it names another model. Dispatch reads `allow_paid` here, not
  from the stored choice, so the record decides.
  """
  @spec serving(String.t() | nil, String.t() | nil) :: map() | nil
  def serving(tenant, model) do
    case get(tenant) do
      {:ok, %{"model" => ^model, "billing" => _} = router} ->
        Map.take(router, ~w(billing allow_paid))

      _ ->
        nil
    end
  end

  @doc """
  Whether a new Agent of the Tenant with this role and purpose takes the
  platform Router's choice: a Router that is not a guest Router.
  """
  @spec applies?(String.t(), String.t() | nil, String.t() | nil) :: boolean()
  def applies?(tenant, role, purpose) do
    role == "router" and purpose != TenantProfiles.guest_router_purpose() and
      not TenantProfiles.router_only?(tenant)
  end

  @doc """
  Set the marked choice on every Router of the Tenant (guest Routers
  excluded). Answers how many Routers now hold it. Reads at most
  #{@max_pages} pages of #{@page} Agents.
  """
  @spec apply(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply(tenant) when is_binary(tenant) do
    case choice(tenant) do
      nil -> {:error, :not_found}
      choice -> apply_pages(tenant, choice, nil, 0, 0)
    end
  end

  defp apply_pages(_tenant, _choice, _cursor, count, @max_pages), do: {:ok, count}

  defp apply_pages(tenant, choice, cursor, count, page) do
    case AgentPGStore.page_configs(%{tenant_id: tenant}, limit: @page, cursor: cursor) do
      {:ok, %{items: records, next: next}} ->
        count =
          Enum.reduce(records, count, fn record, count ->
            if router?(tenant, record) and mark(record, tenant, choice) == :ok,
              do: count + 1,
              else: count
          end)

        if is_nil(next),
          do: {:ok, count},
          else: apply_pages(tenant, choice, next, count, page + 1)

      {:error, _} = error ->
        error
    end
  end

  defp router?(tenant, record) do
    record["tenant_id"] == tenant and AgentControl.visible?(record) and
      applies?(tenant, record["role"], record["purpose"])
  end

  defp mark(record, tenant, choice) do
    case AgentControl.put_platform_model(record["agent_id"], tenant, choice) do
      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning("platform_router_apply_skipped reason=#{inspect(reason)}")
        :error
    end
  end

  defp allow_paid(value) when value in [true, "true"], do: true
  defp allow_paid(value) when value in [nil, false, "false"], do: false
  defp allow_paid(_value), do: :invalid

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
