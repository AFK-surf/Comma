defmodule BridgeForTeams.UserOnboardings do
  @moduledoc """
  Per-user dashboard onboarding state.

  The dashboard shows a first-run flow (capabilities → profile → integrations →
  starter tasks) to users who have not finished it yet; `onboarded?/1` is the
  gate query the web layer runs on every authenticated LiveView mount, so it
  stays a single indexed lookup. `completed` and `skipped` both count as
  finished — skipping is a legitimate way through the flow.
  """
  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.UserOnboarding

  @doc """
  Get the user's onboarding record, creating the initial `in_progress` row when
  none exists yet. Race-safe: concurrent first mounts both land on the same row
  (`on_conflict: :nothing` + re-fetch).
  """
  @spec ensure_onboarding(Ecto.UUID.t()) :: {:ok, UserOnboarding.t()} | {:error, term()}
  def ensure_onboarding(user_id) do
    case get_onboarding(user_id) do
      {:ok, onboarding} ->
        {:ok, onboarding}

      {:error, :not_found} ->
        %UserOnboarding{}
        |> UserOnboarding.changeset(%{user_id: user_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :user_id)

        get_onboarding(user_id)
    end
  end

  @doc "Fetch the user's onboarding record."
  @spec get_onboarding(Ecto.UUID.t()) :: {:ok, UserOnboarding.t()} | {:error, :not_found}
  def get_onboarding(user_id) do
    case Repo.get_by(UserOnboarding, user_id: user_id) do
      nil -> {:error, :not_found}
      onboarding -> {:ok, onboarding}
    end
  end

  @doc """
  Whether the user has finished onboarding (completed or skipped). `false` for
  users with no record yet. This is the mount gate — one indexed query.
  """
  @spec onboarded?(Ecto.UUID.t()) :: boolean()
  def onboarded?(user_id) do
    from(o in UserOnboarding, where: o.user_id == ^user_id, select: o.status)
    |> Repo.one()
    |> case do
      status when status in ["completed", "skipped"] -> true
      _ -> false
    end
  end

  @doc "Record the step the user has reached so a return visit resumes there."
  @spec advance(UserOnboarding.t(), String.t()) ::
          {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def advance(%UserOnboarding{} = onboarding, step) do
    onboarding
    |> UserOnboarding.changeset(%{current_step: step})
    |> Repo.update()
  end

  @doc "Store the capability grants chosen on the capabilities step."
  @spec put_capabilities(UserOnboarding.t(), map()) ::
          {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def put_capabilities(%UserOnboarding{} = onboarding, capabilities) when is_map(capabilities) do
    onboarding
    |> UserOnboarding.changeset(%{capabilities: capabilities})
    |> Repo.update()
  end

  @doc "Store the generated profile model shown on the profile step."
  @spec put_profile(UserOnboarding.t(), map()) ::
          {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def put_profile(%UserOnboarding{} = onboarding, profile) when is_map(profile) do
    onboarding
    |> UserOnboarding.changeset(%{profile: profile})
    |> Repo.update()
  end

  @doc """
  A compact brief of what onboarding captured about the user — identity, key
  contacts, and the granted capabilities — for embedding in agent-facing
  prompts (the assistant rail context, task delegation). `nil` when nothing
  useful was captured, so callers can splice it in unconditionally.

  Machine-facing English by design, like the rest of the prompt contract.
  """
  @spec agent_brief(Ecto.UUID.t()) :: String.t() | nil
  def agent_brief(user_id) do
    case get_onboarding(user_id) do
      {:ok, onboarding} -> compose_brief(onboarding)
      {:error, :not_found} -> nil
    end
  end

  defp compose_brief(%UserOnboarding{} = onboarding) do
    profile = onboarding.profile || %{}

    lines =
      [
        identity_line(profile["identity"]),
        contacts_line(profile["key_contacts"]),
        capabilities_line(onboarding.capabilities)
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [] do
      nil
    else
      Enum.join(["About the user (from onboarding):" | lines], "\n")
    end
  end

  defp identity_line(%{} = identity) do
    name = present(identity["name"]) || present(identity["email"])

    detail =
      [present(identity["role"]), present(identity["org"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" at ")

    cond do
      is_nil(name) -> nil
      detail == "" -> "- #{name}"
      true -> "- #{name} — #{detail}"
    end
  end

  defp identity_line(_identity), do: nil

  defp contacts_line([_ | _] = contacts) do
    named =
      contacts
      |> Enum.map(fn contact ->
        name = present(contact["name"]) || present(contact["email"])
        role = present(contact["role"])
        if name, do: if(role, do: "#{name} (#{role})", else: name)
      end)
      |> Enum.reject(&is_nil/1)

    if named != [], do: "- Key contacts: " <> Enum.join(named, ", ")
  end

  defp contacts_line(_contacts), do: nil

  # `capabilities` mixes boolean grants with bookkeeping (`"_schedules"` holds
  # a map); matching on `true` keeps only real grants.
  defp capabilities_line(%{} = capabilities) do
    granted = for {key, true} <- capabilities, is_binary(key), do: key

    if granted != [] do
      "- Enabled capabilities: " <> (granted |> Enum.sort() |> Enum.join(", "))
    end
  end

  defp capabilities_line(_capabilities), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc "Mark onboarding finished."
  @spec complete(UserOnboarding.t()) :: {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def complete(%UserOnboarding{} = onboarding), do: finish(onboarding, "completed")

  @doc "Mark onboarding skipped (also finishes the flow for gating)."
  @spec skip(UserOnboarding.t()) :: {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def skip(%UserOnboarding{} = onboarding), do: finish(onboarding, "skipped")

  @doc """
  Reopen the flow from the first step, whatever state it is in. Deliberately
  non-destructive: the captured capabilities and profile stay (the wizard
  pre-fills from them, and the `"_schedules"` audit keeps routine
  reconciliation idempotent), and nothing a previous run produced — board
  tasks, report offers, schedules, connections — is touched. The user is back
  behind the onboarding gate until they finish or skip again.
  """
  @spec restart(UserOnboarding.t()) :: {:ok, UserOnboarding.t()} | {:error, Ecto.Changeset.t()}
  def restart(%UserOnboarding{} = onboarding) do
    onboarding
    |> UserOnboarding.changeset(%{
      status: "in_progress",
      current_step: "capabilities",
      completed_at: nil
    })
    |> Repo.update()
  end

  defp finish(onboarding, status) do
    onboarding
    |> UserOnboarding.changeset(%{status: status, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
