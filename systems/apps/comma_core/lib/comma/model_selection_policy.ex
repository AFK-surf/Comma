defmodule Comma.ModelSelectionPolicy do
  @moduledoc "Comma-wide user selection policy for global Agent Templates."

  alias Comma.Repo

  @limit 100

  def get do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT mode, allowed_template_ids, revision FROM comma_model_selection_policy WHERE id = 1",
           [], timeout: 5_000) do
      {:ok, %{rows: [[mode, ids, revision]]}} ->
        {:ok, %{mode: mode, allowed_template_ids: ids, revision: revision}}

      {:ok, _} ->
        {:error, :model_selection_policy_missing}

      {:error, _} ->
        {:error, :model_selection_policy_unavailable}
    end
  end

  def update(attrs) do
    with mode when mode in ["all", "selected"] <- attrs["mode"],
         {:ok, ids} <- normalize_ids(attrs["allowed_template_ids"]),
         revision when is_integer(revision) and revision >= 0 <- attrs["revision"],
         :ok <- validate_global_ids(if(mode == "all", do: [], else: ids)) do
      ids = if mode == "all", do: [], else: ids
      Repo.transaction(fn ->
        %{rows: [[old_mode, old_ids, current]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT mode, allowed_template_ids, revision FROM comma_model_selection_policy WHERE id = 1 FOR UPDATE",
            []
          )

        if revision != current, do: Repo.rollback(:model_selection_policy_conflict)

        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE comma_model_selection_policy SET mode = $1, allowed_template_ids = $2, revision = revision + 1 WHERE id = 1",
          [mode, ids]
        )

        if command_id = attrs["admin_command_id"] do
          Ecto.Adapters.SQL.query!(
            Repo,
            "UPDATE comma_admin_audit_events SET evidence = $2 WHERE id = $1::uuid",
            [
              Ecto.UUID.dump!(command_id),
              %{
                "before" => %{"mode" => old_mode, "allowed_template_ids" => old_ids},
                "after" => %{"mode" => mode, "allowed_template_ids" => ids}
              }
            ]
          )
        end

        %{mode: mode, allowed_template_ids: ids, revision: current + 1}
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_model_selection_policy}
    end
  end

  def allowed?(%{mode: "all"}, _id), do: true
  def allowed?(%{mode: "selected", allowed_template_ids: ids}, id), do: id in ids

  defp normalize_ids(ids) when is_list(ids) and length(ids) <= @limit do
    if Enum.all?(
         ids,
         &(is_binary(&1) and byte_size(&1) <= 200 and String.trim(&1) == &1 and &1 != "")
       ) and
         length(Enum.uniq(ids)) == length(ids),
       do: {:ok, ids},
       else: {:error, :invalid_model_selection_policy}
  end

  defp normalize_ids(_), do: {:error, :invalid_model_selection_policy}

  defp validate_global_ids([]), do: :ok

  defp validate_global_ids(ids) do
    with {:ok, templates} <- SalixAgent.Templates.list_public_bounded(@limit) do
      public_ids = MapSet.new(templates, & &1["template_id"])

      if Enum.all?(ids, &MapSet.member?(public_ids, &1)),
        do: :ok,
        else: {:error, :invalid_model_selection_policy}
    end
  end
end
