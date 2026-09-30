defmodule SalixStore.BrowserSettings do
  @moduledoc "Database-owned Browser Run settings. Credentials never enter public views."
  alias SalixStore.{Repo, Crypto}
  @default "__browser_default__"
  def default_scope, do: @default

  defmodule Row do
    use Ecto.Schema
    @primary_key {:scope, :string, autogenerate: false}
    schema "browser_settings" do
      field(:mode, :string)
      field(:account_id, :string)
      field(:token_ciphertext, :string, redact: true)
      field(:idle_timeout_ms, :integer, default: 60000)
      field(:operation_timeout_ms, :integer, default: 15000)
      field(:allowed_domains, {:array, :string})
      field(:updated_at, :utc_datetime_usec)
    end
  end

  # The deployment credential root is independent of stored rows. Scope-bound
  # AEAD rejects copying ciphertext to another tenant. Only the provider adapter
  # and driver receive plaintext. Missing keys fail browser use closed.
  def seal(token, scope) when is_binary(token) and is_binary(scope) do
    with {:ok, key} <- Crypto.derived_key("browser-provider-credential-v1") do
      iv = :crypto.strong_rand_bytes(12)
      {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, token, scope, true)
      {:ok, Base.encode64(iv <> tag <> cipher)}
    end
  end

  def unseal(encoded, scope) do
    with {:ok, key} <- Crypto.derived_key("browser-provider-credential-v1"),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           Base.decode64(encoded),
         value when is_binary(value) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, scope, tag, false) do
      {:ok, value}
    else
      _ -> {:error, :browser_credentials_unavailable}
    end
  rescue
    _ -> {:error, :browser_credentials_unavailable}
  end

  def view(scope) do
    case Repo.get(Row, scope, log: false) do
      nil ->
        %{
          mode: if(scope == @default, do: "disabled", else: "inherit"),
          account_id: "",
          token_configured: false,
          idle_timeout_ms: 60000,
          operation_timeout_ms: 15000,
          allowed_domains: nil
        }

      row ->
        %{
          mode: row.mode,
          account_id: row.account_id || "",
          token_configured: is_binary(row.token_ciphertext),
          idle_timeout_ms: row.idle_timeout_ms,
          operation_timeout_ms: row.operation_timeout_ms,
          allowed_domains: row.allowed_domains
        }
    end
  rescue
    _ -> %{error: "browser_settings_unavailable"}
  end

  def resolve(tenant_id) when is_binary(tenant_id) and tenant_id != @default do
    case Repo.get(Row, tenant_id, log: false) do
      nil -> selected(Repo.get(Row, @default, log: false))
      %Row{mode: "inherit"} -> selected(Repo.get(Row, @default, log: false))
      row -> selected(row)
    end
  rescue
    _ -> {:error, :browser_settings_unavailable}
  end

  def resolve(_), do: {:error, :browser_not_configured}
  def selected_scope(scope), do: selected(Repo.get(Row, scope, log: false))

  defp selected(%Row{mode: "override", account_id: account, token_ciphertext: token} = row)
       when is_binary(account) and is_binary(token), do: {:ok, row}

  defp selected(%Row{mode: "disabled"}), do: {:error, :browser_disabled}
  defp selected(_), do: {:error, :browser_not_configured}

  def put(scope, attrs) when is_binary(scope) and is_map(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["browser_settings:" <> scope],
        log: false
      )

      current = Repo.get(Row, scope, log: false) || %Row{scope: scope}
      mode = attrs["mode"]
      account = String.trim(attrs["account_id"] || current.account_id || "")
      token = String.trim(attrs["api_token"] || "")

      unless mode in ["disabled", "override", "inherit"] and
               not (scope == @default and mode == "inherit"),
             do: Repo.rollback(:invalid_browser_settings)

      if byte_size(token) > 4096 or
           (mode == "override" and not Regex.match?(~r/^[a-f0-9]{32}$/, account)),
         do: Repo.rollback(:invalid_browser_settings)

      if token == "" and account != (current.account_id || "") and mode == "override",
        do: Repo.rollback(:browser_token_required)

      cipher =
        if token == "" do
          current.token_ciphertext
        else
          case seal(token, scope) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end
        end

      if mode == "override" and is_nil(cipher), do: Repo.rollback(:browser_token_required)

      idle = integer(attrs["idle_timeout_ms"], current.idle_timeout_ms, 1000, 600_000)
      timeout = integer(attrs["operation_timeout_ms"], current.operation_timeout_ms, 1000, 30000)
      domains = Map.get(attrs, "allowed_domains", current.allowed_domains)

      unless is_nil(domains) or
               (is_list(domains) and length(domains) <= 50 and
                  Enum.all?(
                    domains,
                    &(is_binary(&1) and byte_size(&1) <= 253 and
                        Regex.match?(~r/^[a-zA-Z0-9.*-]+$/, &1))
                  )) do
        Repo.rollback(:invalid_browser_domains)
      end

      row = %Row{
        scope: scope,
        mode: mode,
        idle_timeout_ms: idle,
        operation_timeout_ms: timeout,
        allowed_domains: domains,
        account_id: account,
        token_ciphertext: cipher,
        updated_at: DateTime.utc_now()
      }

      Repo.insert!(row,
        on_conflict:
          {:replace,
           [
             :mode,
             :account_id,
             :token_ciphertext,
             :idle_timeout_ms,
             :operation_timeout_ms,
             :allowed_domains,
             :updated_at
           ]},
        conflict_target: :scope,
        log: false
      )

      :ok
    end)
  rescue
    _ -> {:error, :browser_settings_unavailable}
  end

  defp integer(nil, default, _, _), do: default

  defp integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> integer(n, default, min, max)
      _ -> Repo.rollback(:invalid_browser_timeout)
    end
  end

  defp integer(value, _, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp integer(_, _, _, _), do: Repo.rollback(:invalid_browser_timeout)
end
