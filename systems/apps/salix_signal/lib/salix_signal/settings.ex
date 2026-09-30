defmodule SalixSignal.Settings do
  @moduledoc """
  Which Signal account serves a tenant (docs/messaging-voice.md).

  The platform account is the default for every tenant. It is one JSON
  object at `ctl/system/signal.json` (`platform_account_id`), set in the
  Salix dashboard. A tenant may override it with its own account: the
  tenant config `signal_account` (`account_id`), set from Comma admin, Comma
  Settings, the Salix dashboard or the BFT dashboard. There are no
  environment variables or `config.json` entries for Signal.

  Operators set both by E.164 number. The number must belong to a registered
  account (`SalixSignal.Accounts`) that is `active`. The platform account
  must have platform scope; a tenant override may use a platform account or
  an account of that tenant's organization (`{:organization, tenant_id}`).
  Operators register a number on the Salix dashboard page
  `/dash/signal/register` (`Salix.Control.SignalRegistration`).

  An override changes only which account new claim codes use. Existing
  bindings keep the account they were claimed on until they are removed.
  """

  alias SalixSignal.Accounts
  alias SalixStore.{Keys, S3, TenantConfigs}

  @tenant_config "signal_account"
  @e164 ~r/\A\+[1-9]\d{6,14}\z/
  @cas_attempts 3

  @type view :: %{String.t() => term()} | nil

  @doc "The platform account view (`account_id`, `e164`, `state`), or nil when unset."
  @spec platform() :: {:ok, view()} | {:error, term()}
  def platform do
    with {:ok, stored, _etag} <- read_system() do
      {:ok, account_view(stored["platform_account_id"])}
    end
  end

  @doc """
  Sets the platform account by E.164 number, or clears it with nil or "".
  Returns the new `platform/0` view.
  """
  @spec set_platform_number(String.t() | nil) :: {:ok, view()} | {:error, term()}
  def set_platform_number(number) do
    with {:ok, account_id} <- resolve(number, :platform) do
      write_system(account_id, @cas_attempts)
    end
  end

  @doc """
  The Signal view of a tenant: `"override"` (the tenant's own account or
  nil), `"platform"` and `"effective"` (the override, else the platform).
  """
  @spec tenant(String.t()) :: {:ok, map()} | {:error, term()}
  def tenant(tenant_id) when is_binary(tenant_id) do
    with {:ok, platform} <- platform() do
      override =
        case TenantConfigs.get(tenant_id, @tenant_config) do
          {:ok, %{"value" => %{"account_id" => id}}} when is_binary(id) -> account_view(id)
          _ -> nil
        end

      {:ok,
       %{
         "tenant_id" => tenant_id,
         "override" => override,
         "platform" => platform,
         "effective" => usable(override) || usable(platform)
       }}
    end
  end

  @doc """
  Sets the tenant's own Signal number, or clears the override with nil or
  "". Returns `tenant/1`.
  """
  @spec set_tenant_number(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_tenant_number(tenant_id, number) when is_binary(tenant_id) do
    with {:ok, account_id} <- resolve(number, {:tenant, tenant_id}) do
      if is_nil(account_id) do
        :ok = TenantConfigs.delete(tenant_id, @tenant_config)
      else
        {:ok, _} =
          TenantConfigs.put(%{
            "tenant_id" => tenant_id,
            "name" => @tenant_config,
            "value" => %{"account_id" => account_id},
            "updated_at" => System.system_time(:second)
          })
      end

      tenant(tenant_id)
    end
  end

  @doc """
  The account that serves new claims of `tenant_id`: its active override,
  else the active platform account. `{:error, :not_configured}` without one.
  """
  @spec effective_account(String.t()) :: {:ok, map()} | {:error, term()}
  def effective_account(tenant_id) do
    case tenant(tenant_id) do
      {:ok, %{"effective" => %{} = account}} -> {:ok, account}
      {:ok, _view} -> {:error, :not_configured}
      error -> error
    end
  end

  @doc "A public account view (`account_id`, `e164`, `state`, `scope`) or nil."
  @spec account_view(String.t() | nil) :: view()
  def account_view(nil), do: nil

  def account_view(account_id) when is_binary(account_id) do
    case Accounts.get(account_id) do
      {:ok, summary} ->
        %{
          "account_id" => account_id,
          "e164" => summary[:e164],
          "state" => to_string(summary[:state]),
          "scope" => scope_name(summary[:scope])
        }

      _ ->
        # A retired or unreadable account still shows which ID is stored.
        %{"account_id" => account_id, "e164" => nil, "state" => "unavailable", "scope" => nil}
    end
  end

  defp usable(%{"state" => "active"} = view), do: view
  defp usable(_view), do: nil

  defp scope_name(:platform), do: "platform"
  defp scope_name({:organization, _id}), do: "organization"
  defp scope_name(_scope), do: nil

  # ---- resolution ----

  defp resolve(number, _use) when number in [nil, ""], do: {:ok, nil}

  defp resolve(number, use) when is_binary(number) do
    number = String.trim(number)

    cond do
      number == "" ->
        {:ok, nil}

      not Regex.match?(@e164, number) ->
        {:error, {:bad_request, "number must be an E.164 number such as +15551234567"}}

      true ->
        case Accounts.find_by_number(number) do
          {:ok, summary} -> check(summary, use)
          {:error, :not_found} -> {:error, :signal_account_not_found}
          {:error, reason} -> {:error, {:unavailable, reason}}
        end
    end
  end

  defp resolve(_number, _use), do: {:error, {:bad_request, "number must be a string"}}

  defp check(%{state: state}, _use) when state != :active, do: {:error, :signal_account_inactive}
  defp check(%{id: id, scope: :platform}, _use), do: {:ok, id}

  defp check(%{id: id, scope: {:organization, tenant_id}}, {:tenant, tenant_id}),
    do: {:ok, id}

  defp check(_summary, _use), do: {:error, :signal_account_scope}

  # ---- system object ----

  defp read_system do
    case S3.get(Keys.ctl_system_signal()) do
      {:ok, %{body: body} = object} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, map, object[:etag]}
          _ -> {:error, :signal_settings_invalid}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, _} = error ->
        error
    end
  end

  defp write_system(_account_id, 0), do: {:error, :conflict}

  defp write_system(account_id, attempts) do
    with {:ok, stored, etag} <- read_system() do
      next =
        if account_id,
          do: Map.put(stored, "platform_account_id", account_id),
          else: Map.delete(stored, "platform_account_id")

      body = Jason.encode!(next)

      result =
        if etag,
          do: S3.put(Keys.ctl_system_signal(), body, if_match: etag),
          else: S3.put(Keys.ctl_system_signal(), body, if_none_match: "*")

      case result do
        {:ok, _} -> platform()
        {:error, :precondition_failed} -> write_system(account_id, attempts - 1)
        {:error, _} = error -> error
      end
    end
  end
end
