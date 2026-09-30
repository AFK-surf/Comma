defmodule CommaWeb.SubscriptionAccounts do
  @moduledoc "Workspace subscription inputs for the existing tenant account owner."
  alias SalixAgent.AccountPool

  def create(tenant, %{"provider" => provider, "credentials" => credentials} = attrs)
      when provider in ["codex", "claude"] and is_map(credentials),
      do:
        AccountPool.create(
          tenant,
          attrs
          |> Map.take(~w(provider credentials))
          |> Map.put("credential_kind", "subscription_oauth")
        )

  def create(_, _), do: {:error, :invalid_input}

  def update(tenant, id, %{"version" => version} = attrs) when is_binary(version) do
    if (not Map.has_key?(attrs, "disabled") or is_boolean(attrs["disabled"])) and
         (not Map.has_key?(attrs, "credentials") or is_map(attrs["credentials"])) do
      AccountPool.update(tenant, id, Map.take(attrs, ~w(version disabled credentials)))
    else
      {:error, :invalid_input}
    end
  end

  def update(_, _, _), do: {:error, :invalid_input}

  def begin_oauth(tenant, %{"provider" => provider} = attrs)
      when provider in ["codex", "claude"] do
    if not Map.has_key?(attrs, "account_id") or
         (is_binary(attrs["account_id"]) and is_binary(attrs["version"])) do
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
