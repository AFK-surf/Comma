defmodule Comma.LiveStatuses.Status do
  @moduledoc "Generalized Live Activity status projection keyed by `(group_id, live_key)`."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [
    type: :utc_datetime_usec,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  @categories ~w(car delivery flight train transit package order timer progress)
  @statuses ~w(active attention done cancelled failed)
  @accents ~w(auto brand green amber blue red neutral)
  @key_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,63}\z/

  def categories, do: @categories
  def statuses, do: @statuses
  def accents, do: @accents
  def key_pattern, do: @key_pattern

  schema "comma_live_statuses" do
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:live_key, :string)
    field(:conversation_id, :string)
    field(:category, :string)
    field(:status, :string)
    field(:accent, :string, default: "auto")
    field(:title, :string)
    field(:subtitle, :string)
    field(:compact_label, :string)
    field(:eta_at, :utc_datetime_usec)
    field(:progress, :float)
    field(:step_current, :integer)
    field(:step_total, :integer)
    field(:step_label, :string)
    field(:detail_left, :string)
    field(:detail_right, :string)
    field(:alert_title, :string)
    field(:alert_body, :string)
    field(:alert_seq, :integer, default: 0)
    field(:dismiss_after_seconds, :integer, default: 15)
    field(:version, :integer, default: 1)
    field(:started_at, :utc_datetime_usec)
    field(:stale_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :workspace_id,
      :group_id,
      :live_key,
      :conversation_id,
      :category,
      :status,
      :accent,
      :title,
      :subtitle,
      :compact_label,
      :eta_at,
      :progress,
      :step_current,
      :step_total,
      :step_label,
      :detail_left,
      :detail_right,
      :alert_title,
      :alert_body,
      :alert_seq,
      :dismiss_after_seconds,
      :version,
      :started_at,
      :stale_at,
      :expires_at,
      :ended_at
    ])
    |> validate_required([
      :workspace_id,
      :group_id,
      :live_key,
      :category,
      :status,
      :accent,
      :title,
      :alert_seq,
      :dismiss_after_seconds,
      :version,
      :started_at,
      :stale_at,
      :expires_at
    ])
    |> validate_format(:live_key, @key_pattern)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:accent, @accents)
    |> validate_length(:title, min: 1, max: 80)
    |> validate_length(:subtitle, max: 100)
    |> validate_length(:compact_label, max: 16)
    |> validate_length(:step_label, max: 24)
    |> validate_length(:detail_left, max: 48)
    |> validate_length(:detail_right, max: 32)
    |> validate_length(:alert_title, max: 48)
    |> validate_length(:alert_body, max: 120)
    |> validate_number(:progress, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:dismiss_after_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 300
    )
    |> validate_step()
    |> unique_constraint([:group_id, :live_key])
  end

  defp validate_step(changeset) do
    current = get_field(changeset, :step_current)
    total = get_field(changeset, :step_total)

    cond do
      is_nil(current) and is_nil(total) ->
        changeset

      is_integer(current) and is_integer(total) and current in 1..8 and total in 2..8 and
          current <= total ->
        changeset

      true ->
        add_error(
          changeset,
          :step_current,
          "must be 1..8 with step_total in 2..8 and current <= total"
        )
    end
  end
end
