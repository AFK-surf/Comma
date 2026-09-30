defmodule BridgeForTeams.Schema.UserOnboarding do
  @moduledoc """
  Per-user dashboard onboarding record.

  Tracks the first-run flow shown after a user's first sign-in: which step they
  are on, the agent capabilities they granted, and the generated profile model
  they reviewed. One row per user; `status` moves `in_progress` →
  `completed`/`skipped` (both mark the flow finished for gating purposes).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @statuses ~w(in_progress completed skipped)
  @steps ~w(capabilities profile integrations tasks)

  schema "user_onboardings" do
    field :status, :string, default: "in_progress"
    field :current_step, :string, default: "capabilities"
    field :capabilities, :map, default: %{}
    field :profile, :map, default: %{}
    field :completed_at, :utc_datetime_usec

    belongs_to :user, BridgeForTeams.Schema.User

    timestamps()
  end

  @doc "Changeset for a user onboarding record."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(onboarding, attrs) do
    onboarding
    |> cast(attrs, [
      :user_id,
      :status,
      :current_step,
      :capabilities,
      :profile,
      :completed_at
    ])
    |> validate_required([:user_id, :status, :current_step])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:current_step, @steps)
    |> unique_constraint(:user_id)
  end

  @doc "The onboarding step keys, in flow order."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc "The accepted `:status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @type t :: %__MODULE__{}
end
