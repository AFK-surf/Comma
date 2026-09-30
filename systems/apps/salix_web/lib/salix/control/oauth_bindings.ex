defmodule Salix.Control.OAuthBindings do
  @moduledoc """
  Group OAuth binding control-plane API.

  A binding maps a group-visible `(provider, alias)` credential to the stored
  OAuth connection. The binding also owns credential availability through
  `enabled`: missing values are treated as enabled, disabled bindings stay
  listed but must not be injected into runtime environments.
  """

  alias Salix.Control.Store
  alias SalixStore.{Crypto, Keys}

  def list(group_id) do
    group_id
    |> list_records()
    |> Enum.sort_by(&{&1["created_at"] || 0, &1["binding_id"] || ""})
    |> Enum.flat_map(fn binding ->
      case SalixStore.OAuth.get(binding["connection_id"] || "") do
        {:ok, conn} -> [oauth_binding_detail(binding, conn)]
        _ -> []
      end
    end)
  end

  def list_records(group_id) do
    group_id
    |> Keys.ctl_oauth_group_bindings_prefix()
    |> Store.list_records()
  end

  def get(group_id, binding_id),
    do: Store.get_record(Keys.ctl_oauth_group_binding(group_id, binding_id))

  def put(tenant_id, group_id, provider, alias_name, connection_id),
    do: put(tenant_id, group_id, provider, alias_name, connection_id, 5)

  def put_remote_mcp(tenant_id, group_id, provider_key, alias_name, connection_id, metadata) do
    put_provider_kind(
      tenant_id,
      group_id,
      "remote_mcp",
      provider_key,
      alias_name,
      connection_id,
      metadata,
      5
    )
  end

  def put_materialized(
        tenant_id,
        group_id,
        provider,
        alias_name,
        connection_id,
        integration_id
      ) do
    binding_id =
      "oauth-" <>
        String.slice(Crypto.hex(Jason.encode!(["fixed", provider, alias_name])), 0, 32)

    put_materialized_record(
      group_id,
      binding_id,
      %{
        "binding_id" => binding_id,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connection_id" => connection_id,
        "provider" => provider,
        "alias" => alias_name,
        "env_hints" => %{},
        "enabled" => true,
        "metadata" => %{
          "integration_materialized" => true,
          "integration_id" => integration_id
        },
        "created_at" => Store.now(),
        "updated_at" => Store.now()
      },
      integration_id
    )
  end

  def put_materialized_remote_mcp(
        tenant_id,
        group_id,
        provider_key,
        alias_name,
        connection_id,
        integration_id,
        metadata
      ) do
    binding_id =
      "oauth-" <>
        String.slice(
          Crypto.hex(Jason.encode!(["remote_mcp", provider_key, alias_name])),
          0,
          32
        )

    put_materialized_record(
      group_id,
      binding_id,
      %{
        "binding_id" => binding_id,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connection_id" => connection_id,
        "provider" => "remote_mcp",
        "provider_kind" => "remote_mcp",
        "provider_key" => provider_key,
        "alias" => alias_name,
        "env_hints" => %{},
        "enabled" => true,
        "metadata" =>
          metadata
          |> public_metadata()
          |> Map.put("integration_materialized", true)
          |> Map.put("integration_id", integration_id),
        "created_at" => Store.now(),
        "updated_at" => Store.now()
      },
      integration_id
    )
  end

  defp put_materialized_record(group_id, binding_id, record, integration_id) do
    key = Keys.ctl_oauth_group_binding(group_id, binding_id)
    expected_connection_id = record["connection_id"]

    case Store.put_new(key, record) do
      {:ok, record} ->
        {:ok, record, true}

      {:error, :exists} ->
        case Store.get_record(key) do
          {:ok,
           %{
             "connection_id" => connection_id,
             "metadata" => %{
               "integration_materialized" => true,
               "integration_id" => ^integration_id
             }
           } = existing}
          when connection_id == expected_connection_id ->
            {:ok, existing, false}

          {:ok, _existing} ->
            {:error,
             {:conflict, "OAuth provider and alias are already owned by another connection"}}

          error ->
            error
        end

      error ->
        case Store.get_record(key) do
          {:ok,
           %{
             "connection_id" => connection_id,
             "metadata" => %{
               "integration_materialized" => true,
               "integration_id" => ^integration_id
             }
           } = existing}
          when connection_id == expected_connection_id ->
            {:ok, existing, true}

          _not_committed ->
            error
        end
    end
  end

  defp put(_tenant_id, _group_id, _provider, _alias, _conn_id, 0),
    do: {:error, :precondition_failed}

  defp put(tenant_id, group_id, provider, alias_name, connection_id, attempts) do
    existing =
      group_id
      |> list_records()
      |> Enum.find(&(&1["provider"] == provider and &1["alias"] == alias_name))

    case existing do
      nil ->
        binding_id = "oauth-" <> Store.random_id()

        now = Store.now()

        rec = %{
          "binding_id" => binding_id,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "connection_id" => connection_id,
          "provider" => provider,
          "alias" => alias_name,
          "env_hints" => %{},
          "enabled" => true,
          "created_at" => now,
          "updated_at" => now
        }

        case Store.put_new(Keys.ctl_oauth_group_binding(group_id, binding_id), rec) do
          {:ok, rec} ->
            {:ok, rec, nil}

          {:error, :exists} ->
            put(tenant_id, group_id, provider, alias_name, connection_id, attempts - 1)

          other ->
            other
        end

      %{"binding_id" => binding_id} = found ->
        case Store.update_record(Keys.ctl_oauth_group_binding(group_id, binding_id), fn rec ->
               rec
               |> Map.put("connection_id", connection_id)
               |> Map.put_new("enabled", true)
               |> Map.put("updated_at", Store.now())
             end) do
          {:ok, rec} ->
            previous = found["connection_id"]
            previous = if previous && previous != connection_id, do: previous, else: nil
            {:ok, rec, previous}

          {:error, :not_found} ->
            put(tenant_id, group_id, provider, alias_name, connection_id, attempts - 1)

          other ->
            other
        end
    end
  end

  defp put_provider_kind(_tenant_id, _group_id, _kind, _provider_key, _alias, _conn_id, _meta, 0),
    do: {:error, :precondition_failed}

  defp put_provider_kind(
         tenant_id,
         group_id,
         provider_kind,
         provider_key,
         alias_name,
         connection_id,
         metadata,
         attempts
       ) do
    existing =
      group_id
      |> list_records()
      |> Enum.find(fn binding ->
        binding["provider_kind"] == provider_kind and binding["provider_key"] == provider_key and
          binding["alias"] == alias_name
      end)

    now = Store.now()

    case existing do
      nil ->
        binding_id = "oauth-" <> Store.random_id()

        rec = %{
          "binding_id" => binding_id,
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "connection_id" => connection_id,
          "provider" => provider_kind,
          "provider_kind" => provider_kind,
          "provider_key" => provider_key,
          "alias" => alias_name,
          "env_hints" => %{},
          "metadata" => public_metadata(metadata),
          "enabled" => true,
          "created_at" => now,
          "updated_at" => now
        }

        case Store.put_new(Keys.ctl_oauth_group_binding(group_id, binding_id), rec) do
          {:ok, rec} ->
            {:ok, rec, nil}

          {:error, :exists} ->
            put_provider_kind(
              tenant_id,
              group_id,
              provider_kind,
              provider_key,
              alias_name,
              connection_id,
              metadata,
              attempts - 1
            )

          other ->
            other
        end

      %{"binding_id" => binding_id} = found ->
        case Store.update_record(Keys.ctl_oauth_group_binding(group_id, binding_id), fn rec ->
               rec
               |> Map.put("connection_id", connection_id)
               |> Map.put("provider_kind", provider_kind)
               |> Map.put("provider_key", provider_key)
               |> Map.put("metadata", public_metadata(metadata))
               |> Map.put_new("enabled", true)
               |> Map.put("updated_at", now)
             end) do
          {:ok, rec} ->
            previous = found["connection_id"]
            previous = if previous && previous != connection_id, do: previous, else: nil
            {:ok, rec, previous}

          {:error, :not_found} ->
            put_provider_kind(
              tenant_id,
              group_id,
              provider_kind,
              provider_key,
              alias_name,
              connection_id,
              metadata,
              attempts - 1
            )

          other ->
            other
        end
    end
  end

  def count_for_connection(connection_id, opts \\ []) do
    exclude_binding_id = to_string(opts[:exclude_binding_id] || "")

    "ctl/oauth/group_bindings/"
    |> Store.list_records()
    |> Enum.count(fn binding ->
      binding["connection_id"] == connection_id and
        to_string(binding["binding_id"] || "") != exclude_binding_id
    end)
  end

  def disable_remote_mcp(group_id, binding_id, reason) do
    with {:ok, binding} <- get(group_id, binding_id),
         :ok <- ensure_remote_mcp_binding(binding),
         {:ok, rec} <-
           Store.update_record(Keys.ctl_oauth_group_binding(group_id, binding_id), fn rec ->
             metadata =
               rec
               |> Map.get("metadata", %{})
               |> public_metadata()
               |> Map.put("invalidated_reason", to_string(reason || ""))
               |> Map.put("invalidated_at", Store.now())

             rec
             |> Map.put("enabled", false)
             |> Map.put("metadata", metadata)
             |> Map.put("updated_at", Store.now())
           end) do
      {:ok, rec}
    end
  end

  def update(group_id, binding_id, attrs) do
    with {:ok, binding} <- get(group_id, binding_id) do
      new_alias =
        if Map.has_key?(attrs, "alias"),
          do: String.trim(to_string(attrs["alias"] || "")),
          else: binding["alias"] || ""

      if new_alias == "" do
        {:error, {:bad_request, "alias cannot be empty"}}
      else
        env_hints =
          if is_map(attrs["env_hints"]),
            do: attrs["env_hints"],
            else: binding["env_hints"] || %{}

        with {:ok, enabled} <- binding_enabled(attrs, binding),
             {:ok, _rec} <-
               Store.update_record(Keys.ctl_oauth_group_binding(group_id, binding_id), fn rec ->
                 rec
                 |> Map.put("alias", new_alias)
                 |> Map.put("env_hints", env_hints)
                 |> Map.put("enabled", enabled)
                 |> Map.put("updated_at", Store.now())
               end) do
          {:ok,
           %{
             "binding_id" => binding_id,
             "alias" => new_alias,
             "provider" => binding["provider"]
           }}
        end
      end
    end
  end

  def delete(group_id, binding_id),
    do: Store.delete_record(Keys.ctl_oauth_group_binding(group_id, binding_id))

  defp oauth_binding_detail(binding, conn) do
    enabled = enabled?(binding)

    %{
      "binding_id" => binding["binding_id"],
      "group_id" => binding["group_id"],
      "provider" => binding["provider"],
      "provider_kind" => binding["provider_kind"] || "fixed",
      "provider_key" => binding["provider_key"] || binding["provider"],
      "alias" => binding["alias"],
      "connection_id" => binding["connection_id"],
      "enabled" => enabled,
      "provider_account_id" => conn["provider_account_id"] || "",
      "provider_account_name" => conn["provider_account_name"] || "",
      "scopes" => conn["scopes"] || [],
      "expires_at" => conn["expires_at"],
      "status" => if(enabled, do: conn["status"] || "active", else: "disabled"),
      "metadata" =>
        Map.merge(
          public_metadata(binding["metadata"] || %{}),
          public_metadata(conn["metadata"] || %{})
        ),
      "created_at" => binding["created_at"]
    }
  end

  defp binding_enabled(attrs, binding) do
    if Map.has_key?(attrs, "enabled") do
      parse_enabled(attrs["enabled"])
    else
      {:ok, enabled?(binding)}
    end
  end

  defp parse_enabled(value) when value in [true, "true", 1, "1"], do: {:ok, true}
  defp parse_enabled(value) when value in [false, "false", 0, "0"], do: {:ok, false}

  defp parse_enabled(_value),
    do: {:error, {:bad_request, "enabled must be a boolean"}}

  defp ensure_remote_mcp_binding(binding) do
    if binding["provider_kind"] == "remote_mcp" do
      :ok
    else
      {:error, {:bad_request, "OAuth binding is not a remote MCP binding"}}
    end
  end

  defp enabled?(binding), do: Map.get(binding, "enabled", true) != false

  defp public_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), public_metadata(value)} end)
    |> Map.drop([
      "access_token",
      "refresh_token",
      "authorization_code",
      "code_verifier",
      "client_secret",
      "registration_access_token"
    ])
  end

  defp public_metadata(list) when is_list(list), do: Enum.map(list, &public_metadata/1)
  defp public_metadata(value), do: value
end
