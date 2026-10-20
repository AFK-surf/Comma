defmodule BridgeForTeams.Migrations.OrgModelChoices do
  @moduledoc """
  Convert each Organization's template-based model settings into model choices.

  `allowed_template_ids`, `default_router_template_id` and `default_template_id`
  (the Worker default) name Salix templates. Each reference becomes the model
  choice that `convert` answers for it (in a release,
  `SalixAgent.Migrations.OrgModelChoices.choice/3`); a reference that stands for
  nothing is dropped. The pass fills only `allowed_models`,
  `default_router_model` and `default_task_model` that are still empty, so a
  second pass, or a setting an admin saved in the meantime, is left as it is.
  The template columns are read, not changed. Each page reads at most 100
  Organizations.
  """

  import Ecto.Query

  alias BridgeForTeams.Schema.Organization

  @page 100

  @typedoc "`convert.(template_id, tenant_id, role)`; `role` is nil for an allow-list entry."
  @type convert :: (String.t(), String.t(), String.t() | nil ->
                      {:ok, map() | nil} | {:error, term()})

  @spec run(module(), convert()) :: {:ok, %{converted: non_neg_integer()}} | {:error, term()}
  def run(repo, convert), do: page(repo, convert, nil, 0)

  defp page(repo, convert, after_id, count) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id::text, salix_tenant_id, allowed_template_ids, default_router_template_id,
               default_template_id
        FROM organizations
        WHERE ($1::uuid IS NULL OR id > $1::uuid)
        ORDER BY id LIMIT $2
        """,
        [after_id && Ecto.UUID.dump!(after_id), @page]
      )

    result =
      Enum.reduce_while(rows, {:ok, count}, fn row, {:ok, count} ->
        case convert_org(repo, convert, row) do
          {:ok, true} -> {:cont, {:ok, count + 1}}
          {:ok, false} -> {:cont, {:ok, count}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case {result, rows} do
      {{:ok, count}, rows} when length(rows) == @page ->
        [id | _] = List.last(rows)
        page(repo, convert, id, count)

      {{:ok, count}, _rows} ->
        {:ok, %{converted: count}}

      {error, _rows} ->
        error
    end
  end

  defp convert_org(_repo, _convert, [_id, tenant | _]) when not is_binary(tenant),
    do: {:ok, false}

  defp convert_org(repo, convert, [id, tenant, allowed, router, worker]) do
    org = repo.one!(from(o in Organization, where: o.id == ^id))

    with {:ok, allowed} <- allowed(org, allowed || [], tenant, convert),
         {:ok, router} <- default(org.default_router_model, router, tenant, "router", convert),
         {:ok, worker} <- default(org.default_task_model, worker, tenant, "worker", convert) do
      changes =
        %{allowed_models: allowed, default_router_model: router, default_task_model: worker}
        |> Map.reject(fn {_field, value} -> is_nil(value) end)

      if changes == %{} do
        {:ok, false}
      else
        org |> Ecto.Changeset.change(changes) |> repo.update!()
        {:ok, true}
      end
    end
  end

  defp allowed(%Organization{allowed_models: [_ | _]}, _ids, _tenant, _convert), do: {:ok, nil}
  defp allowed(_org, [], _tenant, _convert), do: {:ok, nil}

  defp allowed(_org, ids, tenant, convert) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case convert.(id, tenant, nil) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, choice} -> {:cont, {:ok, [choice | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, choices} -> {:ok, choices |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp default(current, _id, _tenant, _role, _convert) when is_map(current), do: {:ok, nil}

  defp default(nil, id, tenant, role, convert) when is_binary(id) and id != "",
    do: convert.(id, tenant, role)

  defp default(_current, _id, _tenant, _role, _convert), do: {:ok, nil}
end
