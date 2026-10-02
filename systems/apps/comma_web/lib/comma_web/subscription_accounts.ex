defmodule CommaWeb.SubscriptionAccounts do
  @moduledoc "Workspace subscription inputs for the existing tenant account owner."
  alias SalixAgent.AccountPool

  def create(tenant, %{"provider" => provider, "credentials" => credentials} = attrs)
      when is_map(credentials) do
    if AccountPool.provider?(provider),
      do:
        AccountPool.create(
          tenant,
          attrs
          |> Map.take(~w(provider credentials))
          |> Map.put("credential_kind", "subscription_oauth")
        ),
      else: {:error, :invalid_input}
  end

  # An API-key Profile for a Model Catalog source; AccountPool validates it.
  def create(tenant, %{"credential_kind" => "provider_api_key", "source" => source} = attrs)
      when is_binary(source),
      do:
        AccountPool.create(
          tenant,
          Map.take(attrs, ~w(credential_kind source name api_key base_url protocol models))
        )

  def create(_, _), do: {:error, :invalid_input}

  def update(tenant, id, %{"version" => version} = attrs) when is_binary(version) do
    if (not Map.has_key?(attrs, "disabled") or is_boolean(attrs["disabled"])) and
         (not Map.has_key?(attrs, "credentials") or is_map(attrs["credentials"])) and
         (not Map.has_key?(attrs, "name") or is_binary(attrs["name"])) and
         (not Map.has_key?(attrs, "api_key") or is_binary(attrs["api_key"])) do
      AccountPool.update(
        tenant,
        id,
        Map.take(attrs, ~w(version disabled credentials name api_key))
      )
    else
      {:error, :invalid_input}
    end
  end

  def update(_, _, _), do: {:error, :invalid_input}

  def begin_oauth(tenant, %{"provider" => provider} = attrs) do
    if AccountPool.provider?(provider) and
         (not Map.has_key?(attrs, "account_id") or
            (is_binary(attrs["account_id"]) and is_binary(attrs["version"]))) do
      AccountPool.begin_oauth(tenant, Map.take(attrs, ~w(provider account_id version mode)))
    else
      {:error, :invalid_input}
    end
  end

  def begin_oauth(_, _), do: {:error, :invalid_input}

  def complete_oauth(tenant, id, %{"code" => code})
      when is_binary(code) and byte_size(code) <= 8192,
      do: AccountPool.complete_oauth(tenant, id, %{"code" => code})

  def complete_oauth(_, _, _), do: {:error, :invalid_input}
end
