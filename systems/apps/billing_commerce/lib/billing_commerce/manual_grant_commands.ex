defmodule BillingCommerce.ManualGrantCommands do
  @moduledoc """
  Typed human-Admin boundary for package-backed manual grants.

  Comma owns the target Workspace-to-Billing relationship. The browser may choose
  only an issuable package, an explicit expiry, and the audited command
  envelope; account, owner, operator, source, and effective time remain
  server-owned.
  """

  @human_keys ~w(
    confirmation
    expires_at
    idempotency_key
    package_code
    package_version
    reason
  )

  defmodule Issue do
    @moduledoc false

    @enforce_keys [
      :billing_account_id,
      :workspace_id,
      :package_code,
      :package_version,
      :expires_at,
      :idempotency_key,
      :operator_id,
      :reason
    ]
    defstruct [
      :billing_account_id,
      :workspace_id,
      :package_code,
      :package_version,
      :expires_at,
      :idempotency_key,
      :operator_id,
      :reason
    ]

    @type t :: %__MODULE__{}
  end

  alias __MODULE__.Issue

  @spec prepare_human_issue(map(), map(), map(), map()) ::
          {:ok, map()} | {:error, :invalid_manual_grant}
  def prepare_human_issue(
        attrs,
        %{"id" => operator_id},
        %{idempotency_key: idempotency_key, reason: reason},
        target
      )
      when is_map(attrs) and is_binary(operator_id) and is_map(target) do
    with :ok <- validate_allowed_keys(attrs),
         {:ok, workspace_id} <- target_string(target, :workspace_id),
         {:ok, billing_account_id} <- target_string(target, :billing_account_id),
         {:ok, package_code} <- required_string(attrs, :package_code, 200),
         {:ok, package_version} <- required_string(attrs, :package_version, 200),
         {:ok, expires_at} <- datetime(attrs, :expires_at) do
      command = %Issue{
        billing_account_id: billing_account_id,
        workspace_id: workspace_id,
        package_code: package_code,
        package_version: package_version,
        expires_at: expires_at,
        idempotency_key: idempotency_key,
        operator_id: operator_id,
        reason: reason
      }

      {:ok,
       %{
         command: command,
         target_type: "workspace",
         target_id: workspace_id,
         expected_confirmation:
           "issue-workspace-credits:#{workspace_id}:#{package_code}:#{package_version}",
         fingerprint: fingerprint(command)
       }}
    end
  end

  def prepare_human_issue(_attrs, _actor, _contract, _target),
    do: {:error, :invalid_manual_grant}

  @spec bind_admin_command(Issue.t(), String.t()) :: map()
  def bind_admin_command(%Issue{} = command, command_id) when is_binary(command_id) do
    %{
      billing_account_id: command.billing_account_id,
      workspace_id: command.workspace_id,
      package_code: command.package_code,
      package_version: command.package_version,
      source_type: "manual_adjustment",
      source_id: "comma_admin:#{command.workspace_id}",
      source_event_id: command_id,
      idempotency_key: billing_idempotency_key(command_id),
      operator: %{
        "id" => command.operator_id,
        "type" => "comma_admin_user",
        "reason" => command.reason
      },
      valid_from: DateTime.utc_now(),
      expires_at: command.expires_at,
      enforce_product_owner_identity: true,
      metadata: %{
        "admin_command_id" => command_id,
        "workspace_id" => command.workspace_id
      }
    }
  end

  @spec billing_idempotency_key(String.t()) :: String.t()
  def billing_idempotency_key(command_id) when is_binary(command_id),
    do: "comma_admin_grant:#{command_id}"

  defp fingerprint(%Issue{} = command) do
    %{
      "billing_account_id" => command.billing_account_id,
      "expires_at" => DateTime.to_iso8601(command.expires_at),
      "package_code" => command.package_code,
      "package_version" => command.package_version,
      "reason" => command.reason,
      "workspace_id" => command.workspace_id
    }
  end

  defp validate_allowed_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(to_string(&1) in @human_keys)),
      do: :ok,
      else: {:error, :invalid_manual_grant}
  end

  defp target_string(target, key) do
    case fetch(target, key) do
      {:ok, value} -> nonempty_string(value, 320)
      :error -> {:error, :invalid_manual_grant}
    end
  end

  defp required_string(attrs, key, max) do
    case fetch(attrs, key) do
      {:ok, value} -> nonempty_string(value, max)
      :error -> {:error, :invalid_manual_grant}
    end
  end

  defp nonempty_string(value, max) when is_binary(value) and byte_size(value) <= max do
    case String.trim(value) do
      "" -> {:error, :invalid_manual_grant}
      normalized -> {:ok, normalized}
    end
  end

  defp nonempty_string(_value, _max), do: {:error, :invalid_manual_grant}

  defp datetime(attrs, key) do
    case fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
          {:ok, datetime}
        else
          _ -> {:error, :invalid_manual_grant}
        end

      _ ->
        {:error, :invalid_manual_grant}
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, to_string(key))
    end
  end
end
