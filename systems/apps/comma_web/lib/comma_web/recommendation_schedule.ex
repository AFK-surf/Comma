defmodule CommaWeb.RecommendationSchedule do
  @moduledoc "Owns the one shared-Schedules definition for a Routine profile."
  import Ecto.Query
  alias Comma.{Repo, Data.RecommendationProfile}
  alias SalixCluster.Schedules

  def reconcile(profile_id) do
    Repo.transaction(fn ->
      profile =
        Repo.one(from(p in RecommendationProfile, where: p.id == ^profile_id, lock: "FOR UPDATE"))

      if profile do
        profile = reserve_schedule(profile)

        case write_definition(profile) do
          :ok -> profile
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> case do
      {:ok, _profile} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reserve_schedule(%{schedule_id: id} = profile) when is_binary(id), do: profile

  defp reserve_schedule(profile) do
    profile
    |> RecommendationProfile.runtime_changeset(%{schedule_id: SalixStore.Ids.new_schedule_id()})
    |> Repo.update!()
  end

  defp definition(profile) do
    %{
      "receiver" => "comma_recommendation",
      "payload" => %{"profile_id" => profile.id},
      "cron" => "#{profile.schedule_minute} #{profile.schedule_hour} * * *",
      "timezone" => profile.timezone,
      "status" => if(profile.schedule_enabled, do: "active", else: "paused")
    }
  end

  defp write_definition(profile) do
    params = definition(profile)
    # This is an owner-scoped, one-way durable transformation. Generic schedule
    # updates still cannot change a receiver or its authority.
    result =
      SalixStore.Schedules.update(profile.schedule_id, fn current ->
        if owned?(current, profile) do
          updated = current |> Map.drop(~w(agent_id session_id prompt)) |> Map.merge(params)

          with :ok <- Schedules.validate_definition(updated),
               :ok <- Comma.Recommendations.recover_schedule_receipt(profile, current) do
            {:ok, updated, Schedules.next_fire_ms(updated)}
          end
        else
          {:error, :recommendation_schedule_owner_mismatch}
        end
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        case Schedules.create(profile.schedule_id, params) do
          {:ok, _} ->
            :ok

          error ->
            error
        end

      error ->
        error
    end
  end

  defp owned?(
         %{"receiver" => "comma_recommendation", "payload" => %{"profile_id" => id}},
         profile
       ),
       do: id == profile.id

  defp owned?(
         %{"receiver" => receiver, "agent_id" => agent_id, "session_id" => session_id},
         profile
       )
       when receiver in [nil, "agent"],
       do:
         is_binary(profile.agent_id) and agent_id == profile.agent_id and
           session_id == profile.session_id

  defp owned?(_, _), do: false

  # The old hidden renderer has no further execution role. Archival retains its
  # identity and journals, and the existing lifecycle owner stops execution.
  @doc false
  def retire_renderer(profile_id) when is_binary(profile_id) do
    case Repo.get(RecommendationProfile, profile_id) do
      nil -> :ok
      %{agent_id: nil} -> :ok
      profile -> retire_profile_renderer(profile)
    end
  end

  defp retire_profile_renderer(profile) do
    case SalixAgent.AgentControl.get_record(profile.agent_id) do
      {:ok, %{"purpose" => "comma_recommendation"} = agent} ->
        archive =
          if SalixAgent.AgentControl.archived?(agent),
            do: {:ok, agent},
            else: SalixAgent.AgentControl.delete(profile.agent_id)

        with {:ok, _} <- archive do
          SalixAgent.Placement.stop_existing(profile.agent_id,
            reason: :normal,
            timeout: 5_000,
            force: true
          )
        end

      {:error, :not_found} ->
        :ok

      {:ok, _} ->
        {:error, :recommendation_renderer_owner_mismatch}

      error ->
        error
    end
  end
end
