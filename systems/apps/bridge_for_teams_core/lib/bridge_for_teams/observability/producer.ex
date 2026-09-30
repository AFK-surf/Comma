defmodule BridgeForTeams.Observability.Producer do
  @moduledoc """
  Contract for features that emit facts into BFT Operations.

  A producer contract is a small declaration beside the feature adapter. It
  makes the Operations surface semi-automatic: new producers still choose what
  to emit, but they must declare the record types, ownership dimensions,
  evidence allowlist, redaction posture, and permission boundary that let the
  shared UI render those facts safely.
  """

  @type record_type :: :event | :operation_run | :check_result | :audit_log
  @type permission :: :org_member | :org_admin | :owner_admin | :system
  @type redaction :: :required | :not_applicable

  @type t :: %{
          required(:producer) => atom(),
          required(:records) => [record_type()],
          required(:domains) => [String.t()],
          required(:sources) => [String.t()],
          required(:resource_types) => [String.t()],
          required(:evidence_allowlist) => [String.t()],
          required(:permissions) => permission(),
          required(:redaction) => redaction()
        }

  @callback observability_contract() :: t()
  @optional_callbacks observability_contract: 0

  @allowed_records [:event, :operation_run, :check_result, :audit_log]
  @allowed_permissions [:org_member, :org_admin, :owner_admin, :system]
  @allowed_redactions [:required, :not_applicable]
  @required_keys [
    :producer,
    :records,
    :domains,
    :sources,
    :resource_types,
    :evidence_allowlist,
    :permissions,
    :redaction
  ]

  @doc """
  Declares a producer contract for a module that emits Operations facts.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour BridgeForTeams.Observability.Producer
      @observability_contract opts |> Keyword.put_new(:redaction, :required) |> Map.new()

      @impl BridgeForTeams.Observability.Producer
      def observability_contract, do: @observability_contract
    end
  end

  @doc """
  Validates and returns a producer contract.

  Tests should call this for every new producer so Operations can reject
  accidental ad-hoc event sources before they become invisible production
  behavior.
  """
  @spec validate_contract!(module()) :: t()
  def validate_contract!(module) when is_atom(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError, "observability producer #{inspect(module)} is not loaded"
    end

    unless function_exported?(module, :observability_contract, 0) do
      raise ArgumentError,
            "observability producer #{inspect(module)} does not define observability_contract/0"
    end

    module
    |> apply(:observability_contract, [])
    |> validate_contract_map!(module)
  end

  @spec allowed_records() :: [record_type()]
  def allowed_records, do: @allowed_records

  @spec allowed_permissions() :: [permission()]
  def allowed_permissions, do: @allowed_permissions

  @spec allowed_redactions() :: [redaction()]
  def allowed_redactions, do: @allowed_redactions

  defp validate_contract_map!(contract, module) when is_map(contract) do
    missing_keys = Enum.reject(@required_keys, &Map.has_key?(contract, &1))

    if missing_keys != [] do
      raise ArgumentError,
            "observability producer #{inspect(module)} is missing required contract keys: #{inspect(missing_keys)}"
    end

    validate_atom!(contract, module, :producer)
    validate_record_types!(contract, module)
    validate_string_list!(contract, module, :domains, non_empty?: true)
    validate_string_list!(contract, module, :sources, non_empty?: true)
    validate_string_list!(contract, module, :resource_types, non_empty?: true)
    validate_string_list!(contract, module, :evidence_allowlist, non_empty?: false)
    validate_member!(contract, module, :permissions, @allowed_permissions)
    validate_member!(contract, module, :redaction, @allowed_redactions)

    contract
  end

  defp validate_contract_map!(contract, module) do
    raise ArgumentError,
          "observability producer #{inspect(module)} returned #{inspect(contract)}; expected a map"
  end

  defp validate_atom!(contract, module, key) do
    value = Map.fetch!(contract, key)

    unless is_atom(value) and not is_nil(value) do
      raise ArgumentError,
            "observability producer #{inspect(module)} has invalid #{key}: #{inspect(value)}"
    end
  end

  defp validate_record_types!(contract, module) do
    records = Map.fetch!(contract, :records)

    unless non_empty_list?(records) do
      raise ArgumentError,
            "observability producer #{inspect(module)} must declare at least one record type"
    end

    unknown_records = Enum.reject(records, &(&1 in @allowed_records))

    if unknown_records != [] do
      raise ArgumentError,
            "observability producer #{inspect(module)} declares unknown records: #{inspect(unknown_records)}"
    end
  end

  defp validate_string_list!(contract, module, key, opts) do
    value = Map.fetch!(contract, key)
    non_empty? = Keyword.fetch!(opts, :non_empty?)

    cond do
      non_empty? and not non_empty_list?(value) ->
        raise ArgumentError,
              "observability producer #{inspect(module)} must declare a non-empty #{key} list"

      not is_list(value) ->
        raise ArgumentError,
              "observability producer #{inspect(module)} has invalid #{key}: #{inspect(value)}"

      Enum.any?(value, &(not is_binary(&1) or &1 == "")) ->
        raise ArgumentError,
              "observability producer #{inspect(module)} #{key} must contain non-empty strings"

      true ->
        :ok
    end
  end

  defp validate_member!(contract, module, key, allowed_values) do
    value = Map.fetch!(contract, key)

    unless value in allowed_values do
      raise ArgumentError,
            "observability producer #{inspect(module)} has invalid #{key}: #{inspect(value)}"
    end
  end

  defp non_empty_list?(value), do: is_list(value) and value != []
end
