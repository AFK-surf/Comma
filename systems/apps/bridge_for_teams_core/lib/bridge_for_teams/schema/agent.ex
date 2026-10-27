defmodule BridgeForTeams.Schema.Agent do
  @moduledoc """
  A product reference to an Agent in the project's Salix group.
  PostgreSQL stores product identity, association, slot and transfer state.
  `salix` is the current owner record, kept in its native shape for consumers.
  `provisioning` describes the existing initial-create outbox, not Agent lifecycle.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  @roles ~w(router worker)

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
    model: :map,
    llm_config: :map,
    station_binding: :map,
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
      {%{id: agent.id, role: get_field(reference, :role)}, @config_types}
      |> cast(attrs, Map.keys(@config_types) -- [:id])

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

  @doc """
  The instructions the agent runs with, or nil: a Router's own
  `router_system_prompt`, else the shared `system_prompt`
  (`SalixAgent.ToolPolicy.system_prompt/2`).
  """
  @spec instructions(t()) :: String.t() | nil
  def instructions(%__MODULE__{role: "router", salix: record}),
    do: present(record["router_system_prompt"]) || present(record["system_prompt"])

  def instructions(%__MODULE__{salix: record}), do: present(record["system_prompt"])

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp reject_identity_update(%Ecto.Changeset{data: %{id: nil}} = changeset, _attrs, _field),
    do: changeset

  defp reject_identity_update(changeset, attrs, field) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
      add_error(changeset, field, "is immutable")
    else
      changeset
    end
  end

  @type t :: %__MODULE__{}
end
