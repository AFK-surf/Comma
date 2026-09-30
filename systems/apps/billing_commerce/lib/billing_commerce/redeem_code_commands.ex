defmodule BillingCommerce.RedeemCodeCommands do
  @moduledoc """
  Typed command boundary for redeem-code mutations.

  Human Admin requests use a deliberately narrow contract. Deployment-bearer
  callers retain the legacy fields they already own, but both paths are
  normalized before any value reaches the persistence layer.
  """

  @max_postgres_integer 2_147_483_647
  @code_types ~w(one_time_package internal_subscription)
  @statuses ~w(active disabled)
  @common_human_keys ~w(confirmation idempotency_key reason)

  defmodule Create do
    @moduledoc false

    @enforce_keys [
      :code,
      :package_code,
      :package_version,
      :code_type,
      :surface,
      :status,
      :max_redemptions,
      :per_account_limit,
      :valid_from,
      :metadata_json
    ]
    defstruct [
      :id,
      :code,
      :package_code,
      :package_version,
      :code_type,
      :surface,
      :scope_product_owner_type,
      :scope_product_owner_id,
      :status,
      :max_redemptions,
      :per_account_limit,
      :valid_from,
      :expires_at,
      :metadata_json,
      :admin_command_id,
      :repo,
      :sql_runner
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Apply do
    @moduledoc false

    @enforce_keys [
      :selector,
      :billing_account_id,
      :surface,
      :product_owner_type,
      :product_owner_id,
      :idempotency_key,
      :operator_json,
      :at,
      :metadata_json
    ]
    defstruct [
      :selector,
      :billing_account_id,
      :surface,
      :product_owner_type,
      :product_owner_id,
      :idempotency_key,
      :operator_json,
      :at,
      :redemption_id,
      :source_event_id,
      :metadata_json,
      :repo,
      :sql_runner
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Disable do
    @moduledoc false

    @enforce_keys [:id]
    defstruct [:id, :repo, :sql_runner]

    @type t :: %__MODULE__{}
  end

  alias __MODULE__.{Apply, Create, Disable}

  @spec prepare_human_create(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare_human_create(attrs, _actor, contract) when is_map(attrs) and is_map(contract) do
    allowed =
      @common_human_keys ++
        ~w(code expires_at max_redemptions package_code package_version per_account_limit)

    with :ok <- validate_allowed_keys(attrs, allowed, :invalid_redeem_code),
         {:ok, code} <- code_mode(attrs, :invalid_redeem_code),
         {:ok, package_code} <- required_string(attrs, :package_code, 200, :invalid_redeem_code),
         {:ok, package_version} <-
           required_string(attrs, :package_version, 200, :invalid_redeem_code),
         {:ok, max_redemptions} <-
           positive_integer(attrs, :max_redemptions, 10, :invalid_redeem_code),
         {:ok, per_account_limit} <-
           positive_integer(attrs, :per_account_limit, 1, :invalid_redeem_code),
         :ok <-
           validate_limit_pair(
             max_redemptions,
             per_account_limit,
             :invalid_redeem_code
           ),
         {:ok, expires_at} <-
           optional_datetime(attrs, :expires_at, :invalid_redeem_code),
         {:ok, metadata_json} <- encode_json(%{}, :invalid_redeem_code) do
      command = %Create{
        code: code,
        package_code: package_code,
        package_version: package_version,
        code_type: :derive,
        surface: "comma",
        scope_product_owner_type: nil,
        scope_product_owner_id: nil,
        status: "active",
        max_redemptions: max_redemptions,
        per_account_limit: per_account_limit,
        valid_from: :now,
        expires_at: expires_at,
        metadata_json: metadata_json
      }

      {:ok,
       %{
         command: command,
         target_type: "redeem_code",
         target_id: "#{package_code}:#{package_version}",
         expected_confirmation: "create-redeem-code:#{package_code}:#{package_version}",
         fingerprint: fingerprint(command, contract)
       }}
    end
  end

  def prepare_human_create(_attrs, _actor, _contract), do: {:error, :invalid_redeem_code}

  @spec prepare_human_apply(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare_human_apply(attrs, %{"id" => actor_id}, contract)
      when is_map(attrs) and is_map(contract) and is_binary(actor_id) do
    allowed =
      @common_human_keys ++ ~w(billing_account_id id product_owner_id product_owner_type)

    with :ok <- validate_allowed_keys(attrs, allowed, :invalid_redeem_request),
         {:ok, code_id} <- required_string(attrs, :id, 320, :invalid_redeem_request),
         {:ok, billing_account_id} <-
           required_string(attrs, :billing_account_id, 320, :invalid_redeem_request),
         {:ok, product_owner_type} <-
           required_string(attrs, :product_owner_type, 100, :invalid_redeem_request),
         true <- product_owner_type == "workspace",
         {:ok, product_owner_id} <-
           required_string(attrs, :product_owner_id, 320, :invalid_redeem_request),
         {:ok, operator_json} <-
           encode_json(
             %{
               "id" => actor_id,
               "type" => "comma_admin_user",
               "reason" => contract.reason
             },
             :invalid_redeem_request
           ),
         {:ok, metadata_json} <- encode_json(%{}, :invalid_redeem_request) do
      command = %Apply{
        selector: {:id, code_id},
        billing_account_id: billing_account_id,
        surface: "comma",
        product_owner_type: product_owner_type,
        product_owner_id: product_owner_id,
        idempotency_key: contract.idempotency_key,
        operator_json: operator_json,
        at: :now,
        metadata_json: metadata_json
      }

      {:ok,
       %{
         command: command,
         target_type: "billing_account",
         target_id: billing_account_id,
         expected_confirmation: "apply-redeem-code:#{billing_account_id}",
         fingerprint: fingerprint(command, contract)
       }}
    else
      false -> {:error, :invalid_redeem_request}
      {:error, _reason} = error -> error
    end
  end

  def prepare_human_apply(_attrs, _actor, _contract),
    do: {:error, :invalid_redeem_request}

  @spec prepare_human_disable(String.t(), map(), map(), map()) ::
          {:ok, map()} | {:error, atom()}
  def prepare_human_disable(id, attrs, _actor, contract)
      when is_map(attrs) and is_map(contract) do
    with :ok <- validate_allowed_keys(attrs, @common_human_keys, :invalid_redeem_code_id),
         {:ok, code_id} <- nonempty_string(id, 320, :invalid_redeem_code_id) do
      command = %Disable{id: code_id}

      {:ok,
       %{
         command: command,
         target_type: "redeem_code",
         target_id: code_id,
         expected_confirmation: "disable-redeem-code:#{code_id}",
         fingerprint: fingerprint(command, contract)
       }}
    end
  end

  def prepare_human_disable(_id, _attrs, _actor, _contract),
    do: {:error, :invalid_redeem_code_id}

  @spec legacy_create(map()) :: {:ok, Create.t()} | {:error, atom()}
  def legacy_create(attrs) when is_map(attrs) do
    with {:ok, code} <- code_mode(attrs, :invalid_redeem_code),
         {:ok, package_code} <- required_string(attrs, :package_code, 200, :invalid_redeem_code),
         {:ok, package_version} <-
           required_string(attrs, :package_version, 200, :invalid_redeem_code),
         {:ok, code_type} <- enum(attrs, :code_type, @code_types, :invalid_redeem_code_type),
         {:ok, surface} <- required_string(attrs, :surface, 100, :invalid_redeem_code),
         {:ok, scope_type, scope_id} <- scope(attrs),
         {:ok, status} <- optional_enum(attrs, :status, @statuses, "active", :invalid_redeem_code),
         {:ok, max_redemptions} <-
           positive_integer(attrs, :max_redemptions, nil, :invalid_redeem_code),
         {:ok, per_account_limit} <-
           positive_integer(attrs, :per_account_limit, 1, :invalid_redeem_code),
         :ok <-
           validate_limit_pair(
             max_redemptions,
             per_account_limit,
             :invalid_redeem_code
           ),
         {:ok, valid_from} <- datetime_or_now(attrs, :valid_from, :invalid_redeem_code),
         {:ok, expires_at} <- optional_datetime(attrs, :expires_at, :invalid_redeem_code),
         :ok <- validate_datetime_order(valid_from, expires_at, :invalid_redeem_code),
         {:ok, metadata} <- optional_map(attrs, :metadata, %{}, :invalid_redeem_code),
         {:ok, metadata_json} <- encode_json(metadata, :invalid_redeem_code),
         {:ok, id} <- optional_string(attrs, :id, 320, :invalid_redeem_code),
         {:ok, admin_command_id} <- optional_uuid(attrs, :admin_command_id),
         do:
           {:ok,
            %Create{
              id: id,
              code: code,
              package_code: package_code,
              package_version: package_version,
              code_type: code_type,
              surface: surface,
              scope_product_owner_type: scope_type,
              scope_product_owner_id: scope_id,
              status: status,
              max_redemptions: max_redemptions,
              per_account_limit: per_account_limit,
              valid_from: valid_from,
              expires_at: expires_at,
              metadata_json: metadata_json,
              admin_command_id: admin_command_id,
              repo: internal_option(attrs, :repo),
              sql_runner: internal_option(attrs, :sql_runner)
            }}
  end

  def legacy_create(_attrs), do: {:error, :invalid_redeem_code}

  @spec legacy_apply(map()) :: {:ok, Apply.t()} | {:error, atom()}
  def legacy_apply(attrs) when is_map(attrs) do
    with {:ok, selector} <- redeem_selector(attrs),
         {:ok, billing_account_id} <-
           required_string(attrs, :billing_account_id, 320, :invalid_redeem_request),
         {:ok, surface} <- required_string(attrs, :surface, 100, :invalid_redeem_request),
         {:ok, product_owner_type} <-
           required_string(attrs, :product_owner_type, 100, :invalid_redeem_request),
         {:ok, product_owner_id} <-
           required_string(attrs, :product_owner_id, 320, :invalid_redeem_request),
         {:ok, idempotency_key} <-
           optional_string(attrs, :idempotency_key, 500, :invalid_redeem_request),
         {:ok, operator} <- operator(attrs),
         {:ok, operator_json} <- encode_json(operator, :operator_id_required),
         {:ok, at} <- datetime_or_now(attrs, :at, :invalid_redeem_request),
         {:ok, redemption_id} <-
           optional_string(attrs, :redemption_id, 320, :invalid_redeem_request),
         {:ok, source_event_id} <-
           optional_string(attrs, :source_event_id, 500, :invalid_redeem_request),
         {:ok, metadata} <- optional_map(attrs, :metadata, %{}, :invalid_redeem_request),
         {:ok, metadata_json} <- encode_json(metadata, :invalid_redeem_request) do
      {:ok,
       %Apply{
         selector: selector,
         billing_account_id: billing_account_id,
         surface: surface,
         product_owner_type: product_owner_type,
         product_owner_id: product_owner_id,
         idempotency_key: idempotency_key,
         operator_json: operator_json,
         at: at,
         redemption_id: redemption_id,
         source_event_id: source_event_id,
         metadata_json: metadata_json,
         repo: internal_option(attrs, :repo),
         sql_runner: internal_option(attrs, :sql_runner)
       }}
    end
  end

  def legacy_apply(_attrs), do: {:error, :invalid_redeem_request}

  @spec legacy_disable(map()) :: {:ok, Disable.t()} | {:error, atom()}
  def legacy_disable(attrs) when is_map(attrs) do
    with {:ok, id} <- required_string(attrs, :id, 320, :invalid_redeem_code_id) do
      {:ok,
       %Disable{
         id: id,
         repo: internal_option(attrs, :repo),
         sql_runner: internal_option(attrs, :sql_runner)
       }}
    end
  end

  def legacy_disable(_attrs), do: {:error, :invalid_redeem_code_id}

  @spec bind_admin_command(Create.t() | Apply.t() | Disable.t(), String.t()) ::
          Create.t() | Apply.t() | Disable.t()
  def bind_admin_command(%Create{} = command, command_id),
    do: %{command | admin_command_id: command_id}

  def bind_admin_command(%Apply{} = command, command_id),
    do: %{command | source_event_id: command_id}

  def bind_admin_command(%Disable{} = command, _command_id), do: command

  defp fingerprint(%Create{} = command, contract) do
    %{
      "code" => fingerprint_code(command.code),
      "expires_at" => canonical_datetime(command.expires_at),
      "max_redemptions" => command.max_redemptions,
      "package_code" => command.package_code,
      "package_version" => command.package_version,
      "per_account_limit" => command.per_account_limit,
      "reason" => contract.reason,
      "surface" => command.surface
    }
  end

  defp fingerprint(%Apply{} = command, contract) do
    %{
      "billing_account_id" => command.billing_account_id,
      "product_owner_id" => command.product_owner_id,
      "product_owner_type" => command.product_owner_type,
      "reason" => contract.reason,
      "redeem_code" => fingerprint_selector(command.selector),
      "surface" => command.surface
    }
  end

  defp fingerprint(%Disable{} = command, contract),
    do: %{"id" => command.id, "reason" => contract.reason}

  defp code_mode(attrs, error) do
    case fetch(attrs, :code) do
      :error ->
        {:ok, :generate}

      {:ok, value} when is_binary(value) ->
        code = normalize_code(value)

        if String.length(code) >= 9 and String.length(code) <= 200 and
             byte_size(code) <= 1_024,
           do: {:ok, {:provided, code}},
           else: {:error, error}

      {:ok, _value} ->
        {:error, error}
    end
  end

  defp redeem_selector(attrs) do
    case {fetch(attrs, :id), fetch(attrs, :code)} do
      {{:ok, id}, :error} ->
        with {:ok, id} <- nonempty_string(id, 320, :invalid_redeem_request),
             do: {:ok, {:id, id}}

      {:error, {:ok, code}} when is_binary(code) ->
        code = normalize_code(code)

        if code == "",
          do: {:error, :invalid_redeem_request},
          else: {:ok, {:code, code}}

      _ ->
        {:error, :invalid_redeem_request}
    end
  end

  defp operator(attrs) do
    case fetch(attrs, :operator) do
      {:ok, operator} when is_map(operator) ->
        with {:ok, id} <- required_string(operator, :id, 320, :operator_id_required),
             {:ok, type} <- optional_string(operator, :type, 100, :operator_id_required),
             {:ok, reason} <-
               optional_string(operator, :reason, 500, :operator_id_required) do
          {:ok,
           %{
             "id" => id,
             "type" => type || "operator",
             "reason" => reason
           }}
        end

      _ ->
        {:error, :operator_id_required}
    end
  end

  defp scope(attrs) do
    with {:ok, type} <-
           optional_string(attrs, :scope_product_owner_type, 100, :invalid_redeem_code),
         {:ok, id} <-
           optional_string(attrs, :scope_product_owner_id, 320, :invalid_redeem_code) do
      if (is_nil(type) and is_nil(id)) or (is_binary(type) and is_binary(id)),
        do: {:ok, type, id},
        else: {:error, :invalid_redeem_code}
    end
  end

  defp required_string(attrs, key, max, error) do
    case fetch(attrs, key) do
      {:ok, value} -> nonempty_string(value, max, error)
      :error -> {:error, error}
    end
  end

  defp optional_string(attrs, key, max, error) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, value} -> nonempty_string(value, max, error)
    end
  end

  defp nonempty_string(value, max, error)
       when is_binary(value) and byte_size(value) <= max do
    value = String.trim(value)
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp nonempty_string(_value, _max, error), do: {:error, error}

  defp enum(attrs, key, values, error) do
    case fetch(attrs, key) do
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, error}
      :error -> {:error, error}
    end
  end

  defp optional_enum(attrs, key, values, default, error) do
    case fetch(attrs, key) do
      :error -> {:ok, default}
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, error}
    end
  end

  defp positive_integer(attrs, key, default, error) do
    case fetch(attrs, key) do
      :error ->
        {:ok, default}

      {:ok, value}
      when is_integer(value) and value > 0 and value <= @max_postgres_integer ->
        {:ok, value}

      _ ->
        {:error, error}
    end
  end

  defp validate_limit_pair(nil, _per_account_limit, _error), do: :ok

  defp validate_limit_pair(max_redemptions, per_account_limit, error) do
    if per_account_limit <= max_redemptions, do: :ok, else: {:error, error}
  end

  defp datetime_or_now(attrs, key, error) do
    case fetch(attrs, key) do
      :error -> {:ok, :now}
      {:ok, value} -> datetime(value, error)
    end
  end

  defp optional_datetime(attrs, key, error) do
    case fetch(attrs, key) do
      :error -> {:ok, nil}
      {:ok, value} -> datetime(value, error)
    end
  end

  defp datetime(%DateTime{} = value, _error), do: {:ok, value}

  defp datetime(value, error) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> {:error, error}
    end
  end

  defp datetime(_value, error), do: {:error, error}

  defp validate_datetime_order(_valid_from, nil, _error), do: :ok
  defp validate_datetime_order(:now, _expires_at, _error), do: :ok

  defp validate_datetime_order(%DateTime{} = valid_from, %DateTime{} = expires_at, error) do
    if DateTime.compare(expires_at, valid_from) == :gt, do: :ok, else: {:error, error}
  end

  defp optional_map(attrs, key, default, error) do
    case fetch(attrs, key) do
      :error -> {:ok, default}
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp encode_json(value, error) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, error}
    end
  end

  defp optional_uuid(attrs, key) do
    case fetch(attrs, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :invalid_admin_command_id}
        end

      {:ok, _value} ->
        {:error, :invalid_admin_command_id}
    end
  end

  defp validate_allowed_keys(attrs, allowed, error) do
    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)),
      do: :ok,
      else: {:error, error}
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(attrs, to_string(key))
    end
  end

  defp internal_option(attrs, key), do: Map.get(attrs, key)

  defp normalize_code(code), do: code |> String.trim() |> String.upcase()
  defp fingerprint_code(:generate), do: %{"mode" => "generate"}
  defp fingerprint_code({:provided, code}), do: %{"mode" => "provided", "value" => code}
  defp fingerprint_selector({kind, value}), do: %{"kind" => to_string(kind), "value" => value}
  defp canonical_datetime(nil), do: nil
  defp canonical_datetime(:now), do: "server_now"
  defp canonical_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
