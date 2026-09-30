defmodule BridgeForTeams.Schema.Agent do
  @moduledoc """
  A product reference to an Agent in the project's Salix group.
  PostgreSQL stores product identity, association, slot and transfer state.
  `salix` is the current owner record, kept in its native shape for consumers.
  `provisioning` describes the existing initial-create outbox, not Agent lifecycle.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SalixStore.RuntimeIds

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @roles ~w(router worker)
  @vm_keys ~w(enabled provider recreate)
  @vm_providers ~w(cloudflare)
  @legacy_external_runtime_config_keys ~w(
    device_id
    device_runtime_id
    kind
    model
    model_provider
    provider
    reasoning_effort
    runtime_id
  )
  @connected_runtime_config_keys ~w(
    binding_revision
    device_id
    device_runtime_id
    kind
    owner_scope
    provider
    runtime_id
  )
  @compute_runtime_config_keys ~w(
    binding_revision
    kind
    owner_scope
    runtime_spec
    workload_id
  )

  schema "agents" do
    field(:salix_agent_id, :string)
    field(:role, :string)
    field(:slot, :string)
    field(:configuration_authority, :string, default: "legacy")
    field(:salix, :map, virtual: true, default: %{})
    field(:provisioning, :string, virtual: true)

    belongs_to(:project, BridgeForTeams.Schema.Project)

    timestamps()
  end

  @doc "The valid agent roles."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @config_types %{
    id: :binary_id,
    role: :string,
    name: :string,
    purpose: :string,
    template_id: :string,
    llm_config: :map,
    runtime_config: :map,
    vm: :map,
    system_prompt: :string
  }

  @doc "Validate product references and initial input without persisting configuration."
  def changeset(agent, attrs) do
    reference =
      agent
      |> cast(attrs, [:project_id, :salix_agent_id, :role, :slot])
      |> reject_identity_update(attrs, :salix_agent_id)
      |> validate_required([:project_id, :salix_agent_id, :role])
      |> validate_inclusion(:role, @roles)
      |> unique_constraint(:salix_agent_id)

    input =
      {%{id: agent.id, role: get_field(reference, :role), vm: agent.salix["vm"]}, @config_types}
      |> cast(attrs, Map.keys(@config_types) -- [:id])
      |> validate_runtime_config()
      |> validate_vm()

    if input.valid? do
      record =
        Map.new(input.changes, fn
          {:purpose, value} -> {"management_purpose", value}
          {key, value} -> {Atom.to_string(key), value}
        end)
        |> then(&Map.merge(agent.salix, &1))
        |> Map.put("agent_id", get_field(reference, :salix_agent_id))
        |> Map.put("role", get_field(reference, :role))

      put_change(reference, :salix, record)
    else
      Enum.reduce(Enum.reverse(input.errors), reference, fn {field, {message, opts}}, acc ->
        add_error(acc, field, message, opts)
      end)
    end
  end

  def active?(%__MODULE__{provisioning: nil, salix: %{"agent_id" => id} = record}),
    do: is_binary(id) and not Map.has_key?(record, "archived_at")

  def active?(_), do: false

  def lifecycle(%__MODULE__{provisioning: state}) when is_binary(state), do: state

  def lifecycle(%__MODULE__{salix: record}) when map_size(record) == 0, do: "unavailable"

  def lifecycle(%__MODULE__{salix: record}),
    do: if(Map.has_key?(record, "archived_at"), do: "archived", else: "active")

  defp reject_identity_update(%Ecto.Changeset{data: %{id: nil}} = changeset, _attrs, _field),
    do: changeset

  defp reject_identity_update(changeset, attrs, field) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
      add_error(changeset, field, "is immutable")
    else
      changeset
    end
  end

  defp validate_runtime_config(changeset) do
    case get_change(changeset, :runtime_config, :unchanged) do
      :unchanged ->
        changeset

      nil ->
        changeset

      config when is_map(config) ->
        validate_runtime_config_kind(changeset, config_value(config, "kind"), config)

      _other ->
        add_error(changeset, :runtime_config, "is invalid")
    end
  end

  defp validate_runtime_config_kind(changeset, kind, _config) when kind in [nil, ""] do
    add_error(changeset, :runtime_config, "must include kind")
  end

  defp validate_runtime_config_kind(changeset, "internal", config) do
    if runtime_config_keys(config) == ["kind"] do
      changeset
    else
      add_error(changeset, :runtime_config, "must only include kind for internal runtime")
    end
  end

  defp validate_runtime_config_kind(changeset, "external", config) do
    changeset
    |> validate_runtime_config_keys(
      config,
      @legacy_external_runtime_config_keys,
      "contains unsupported external runtime fields"
    )
    |> validate_external_role()
    |> validate_config_member(
      config,
      "provider",
      RuntimeIds.external_runtime_providers(),
      "must use a supported external runtime provider"
    )
    |> validate_config_required(config, "device_id")
    |> validate_config_required(config, "runtime_id")
    |> validate_config_required(config, "device_runtime_id")
  end

  defp validate_runtime_config_kind(changeset, "connected_runtime", config) do
    changeset
    |> validate_runtime_config_keys(
      config,
      @connected_runtime_config_keys,
      "contains unsupported connected runtime fields"
    )
    |> validate_external_role()
    |> validate_config_member(
      config,
      "provider",
      RuntimeIds.external_runtime_providers(),
      "must use a supported external runtime provider"
    )
    |> validate_config_required(config, "device_id")
    |> validate_config_required(config, "runtime_id")
    |> validate_config_required(config, "device_runtime_id")
    |> validate_binding_revision(config)
    |> validate_owner_scope(config, "group")
  end

  defp validate_runtime_config_kind(changeset, "compute_workload", config) do
    changeset
    |> validate_runtime_config_keys(
      config,
      @compute_runtime_config_keys,
      "contains unsupported compute workload fields"
    )
    |> validate_external_role()
    |> validate_config_required(config, "workload_id")
    |> validate_binding_revision(config)
    |> validate_owner_scope(config, "project")
    |> validate_runtime_spec(config)
  end

  defp validate_runtime_config_kind(changeset, _kind, _config) do
    add_error(changeset, :runtime_config, "has an unsupported kind")
  end

  defp validate_external_role(changeset) do
    if get_field(changeset, :role) == "worker" do
      changeset
    else
      add_error(changeset, :role, "must be worker for external runtime agents")
    end
  end

  defp validate_runtime_config_keys(changeset, config, allowed_keys, message) do
    case runtime_config_keys(config) -- allowed_keys do
      [] -> changeset
      unknown -> add_error(changeset, :runtime_config, "#{message}: #{Enum.join(unknown, ", ")}")
    end
  end

  defp validate_config_member(changeset, config, key, expected, message) do
    if config_value(config, key) in expected do
      changeset
    else
      add_error(changeset, :runtime_config, message)
    end
  end

  defp validate_config_required(changeset, config, key) do
    case config_value(config, key) do
      value when is_binary(value) and value != "" -> changeset
      _ -> add_error(changeset, :runtime_config, "must include #{key}")
    end
  end

  defp validate_binding_revision(changeset, config) do
    case config_value(config, "binding_revision") do
      revision when is_integer(revision) and revision > 0 -> changeset
      _ -> add_error(changeset, :runtime_config, "must include a positive binding_revision")
    end
  end

  defp validate_owner_scope(changeset, config, expected_type) do
    case config_value(config, "owner_scope") do
      scope when is_map(scope) ->
        type = config_value(scope, "type")
        id = config_value(scope, "id")

        if runtime_config_keys(scope) == ["id", "type"] and type == expected_type and
             is_binary(id) and id != "" do
          changeset
        else
          add_error(changeset, :runtime_config, "must include exact #{expected_type} owner_scope")
        end

      _ ->
        add_error(changeset, :runtime_config, "must include exact #{expected_type} owner_scope")
    end
  end

  defp validate_runtime_spec(changeset, config) do
    case config_value(config, "runtime_spec") do
      runtime_spec when is_map(runtime_spec) ->
        provider = config_value(runtime_spec, "provider")

        if runtime_config_keys(runtime_spec) == ["provider"] and
             provider in ["codex", "pi", "claude"] do
          changeset
        else
          add_error(changeset, :runtime_config, "must include a supported runtime_spec provider")
        end

      _ ->
        add_error(changeset, :runtime_config, "must include a supported runtime_spec provider")
    end
  end

  defp config_value(config, key) do
    Map.get(config, key) || Map.get(config, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(config, key)
  end

  defp runtime_config_keys(config) do
    config
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp validate_vm(changeset) do
    case get_change(changeset, :vm, :unchanged) do
      :unchanged ->
        changeset

      nil ->
        changeset

      vm when is_map(vm) ->
        changeset
        |> validate_vm_keys(vm)
        |> validate_vm_enabled(vm)
        |> validate_vm_provider(vm)
        |> validate_vm_recreate(vm)
        |> validate_vm_transition(vm)
        |> strip_vm_command_flags()

      _other ->
        add_error(changeset, :vm, "is invalid")
    end
  end

  defp validate_vm_keys(changeset, vm) do
    case runtime_config_keys(vm) -- @vm_keys do
      [] ->
        changeset

      unknown ->
        add_error(changeset, :vm, "contains unsupported VM fields: #{Enum.join(unknown, ", ")}")
    end
  end

  defp validate_vm_enabled(changeset, vm) do
    case config_value(vm, "enabled") do
      nil -> changeset
      enabled when is_boolean(enabled) -> changeset
      _other -> add_error(changeset, :vm, "enabled must be boolean")
    end
  end

  defp validate_vm_provider(changeset, vm) do
    case config_value(vm, "provider") do
      nil -> changeset
      "" -> changeset
      provider when provider in @vm_providers -> changeset
      _other -> add_error(changeset, :vm, "provider must be cloudflare")
    end
  end

  defp validate_vm_recreate(changeset, vm) do
    case config_value(vm, "recreate") do
      nil -> changeset
      recreate when is_boolean(recreate) -> changeset
      _other -> add_error(changeset, :vm, "recreate must be boolean")
    end
  end

  defp validate_vm_transition(%Ecto.Changeset{data: %{id: nil}} = changeset, vm) do
    if config_value(vm, "recreate") in [nil, false] do
      changeset
    else
      add_error(changeset, :vm, "recreate is only supported when changing VM provider")
    end
  end

  defp validate_vm_transition(%Ecto.Changeset{data: data} = changeset, vm) do
    current = normalize_map(Map.get(data, :vm) || %{})
    requested = normalize_map(vm)

    current_enabled? = current["enabled"] == true
    requested_enabled? = requested["enabled"] == true

    provider_changed? =
      current_enabled? and requested_enabled? and requested["provider"] != current["provider"]

    cond do
      provider_changed? and requested["recreate"] != true ->
        add_error(changeset, :vm, "provider change requires recreate=true")

      not provider_changed? and requested["recreate"] == true ->
        add_error(changeset, :vm, "recreate is only supported when changing VM provider")

      true ->
        changeset
    end
  end

  defp strip_vm_command_flags(%Ecto.Changeset{} = changeset) do
    update_change(changeset, :vm, fn
      vm when is_map(vm) -> Map.drop(vm, ["recreate", :recreate])
      vm -> vm
    end)
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_map(_), do: %{}

  @type t :: %__MODULE__{}
end
