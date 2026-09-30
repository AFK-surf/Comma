defmodule SalixMeet.Release do
  @moduledoc """
  Online release backfill for the PostgreSQL meeting group projection.

  The projection-first writer shipped in PR #934 and reached the fleet before
  the later `salix-20260831000101` online migration began invoking this
  entrypoint. Both the previous and candidate runtime therefore write the
  PostgreSQL row before creating authoritative S3 state, so an idempotent online
  pass can fill legacy rows and seal readiness without stopping serving traffic.

  Runtime and operator audits are read-only. They can detect drift after the
  marker is sealed. A later online release pass can repair missing rows; it
  never deletes extra rows while projection-first writers are live.
  """

  alias SalixMeet.Store
  alias SalixStore.{MeetingGroupProjectionReadiness, MeetingGroupProjections}

  @doc "Online release entrypoint; call only after the projection-first writer has reached every environment."
  @spec run_online_group_projection_backfill() :: :ok | {:error, term()}
  def run_online_group_projection_backfill do
    with {:ok, meeting_ids} <- Store.list(),
         {:ok, plan} <- projection_plan(meeting_ids),
         :ok <- project_rows(Enum.reverse(plan.rows)),
         {:ok, projected_count} <- verify_all(meeting_ids),
         :ok <- verify_projection_count(projected_count),
         :ok <- MeetingGroupProjections.mark_ready(plan.counts),
         :ok <- MeetingGroupProjectionReadiness.refresh() do
      :ok
    end
  end

  @doc "Read-only exact audit of every authoritative meeting after readiness is sealed."
  @spec audit_group_projection() :: :ok | {:error, term()}
  def audit_group_projection do
    with :ok <- require_sealed_marker(),
         {:ok, meeting_ids} <- Store.list(),
         {:ok, projected_count} <- verify_all(meeting_ids),
         :ok <- verify_projection_count(projected_count) do
      :ok
    end
  end

  @doc "Read-only bounded audit page used by the periodic drift detector."
  @spec audit_group_projection_page(keyword()) ::
          {:ok, %{continuation_token: String.t() | nil, projected_count: non_neg_integer()}}
          | {:error, term()}
  def audit_group_projection_page(opts \\ [])

  def audit_group_projection_page(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      projected_count = Keyword.get(opts, :projected_count, 0)
      list_opts = Keyword.take(opts, [:page_size, :continuation_token])

      with true <- is_integer(projected_count) and projected_count >= 0,
           true <- Keyword.keys(opts) -- [:page_size, :continuation_token, :projected_count] == [],
           :ok <- require_sealed_marker(),
           {:ok, page} <- Store.list_page(list_opts),
           {:ok, page_count} <- verify_all(page.meeting_ids),
           total = projected_count + page_count,
           :ok <- maybe_verify_projection_count(page.continuation_token, total) do
        {:ok, %{continuation_token: page.continuation_token, projected_count: total}}
      else
        false -> {:error, :invalid}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid}
    end
  end

  def audit_group_projection_page(_opts), do: {:error, :invalid}

  defp projection_plan(meeting_ids) do
    Enum.reduce_while(
      meeting_ids,
      {:ok,
       %{
         rows: [],
         counts: %{
           "meeting_state_count" => 0,
           "projected_meeting_count" => 0,
           "unscoped_meeting_count" => 0
         }
       }},
      fn meeting_id, {:ok, plan} ->
        case Store.get(meeting_id) do
          {:ok, %{"state" => %{"group_id" => group_id}}, _etag}
          when is_binary(group_id) and group_id != "" ->
            {:cont,
             {:ok,
              %{
                rows: [{meeting_id, group_id} | plan.rows],
                counts:
                  plan.counts
                  |> Map.update!("meeting_state_count", &(&1 + 1))
                  |> Map.update!("projected_meeting_count", &(&1 + 1))
              }}}

          {:ok, %{"state" => state}, _etag} when is_map(state) ->
            {:cont,
             {:ok,
              %{
                plan
                | counts:
                    plan.counts
                    |> Map.update!("meeting_state_count", &(&1 + 1))
                    |> Map.update!("unscoped_meeting_count", &(&1 + 1))
              }}}

          other ->
            {:halt, {:error, {:state_unreadable, meeting_id, other}}}
        end
      end
    )
  end

  defp project_rows(rows) do
    Enum.reduce_while(rows, :ok, fn {meeting_id, group_id}, :ok ->
      case MeetingGroupProjections.ensure(group_id, meeting_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:projection_write_failed, meeting_id, reason}}}
      end
    end)
  end

  defp verify_all(meeting_ids) do
    Enum.reduce_while(meeting_ids, {:ok, 0}, fn meeting_id, {:ok, projected_count} ->
      case Store.get(meeting_id) do
        {:ok, %{"state" => %{"group_id" => group_id}}, _etag}
        when is_binary(group_id) and group_id != "" ->
          case MeetingGroupProjections.fetch_group(meeting_id) do
            {:ok, ^group_id} -> {:cont, {:ok, projected_count + 1}}
            other -> {:halt, {:error, {:projection_mismatch, meeting_id, other}}}
          end

        {:ok, %{"state" => state}, _etag} when is_map(state) ->
          {:cont, {:ok, projected_count}}

        other ->
          {:halt, {:error, {:state_unreadable, meeting_id, other}}}
      end
    end)
  end

  defp maybe_verify_projection_count(nil, expected_count),
    do: verify_projection_count(expected_count)

  defp maybe_verify_projection_count(_continuation_token, _expected_count), do: :ok

  defp verify_projection_count(expected_count) do
    case MeetingGroupProjections.count() do
      {:ok, ^expected_count} -> :ok
      {:ok, actual_count} -> {:error, {:projection_count_mismatch, expected_count, actual_count}}
      {:error, reason} -> {:error, {:projection_count_unavailable, reason}}
    end
  end

  defp require_sealed_marker do
    case MeetingGroupProjections.marker_status() do
      :present -> :ok
      :absent -> {:error, :meeting_source_unsealed}
      {:error, reason} -> {:error, {:marker_unreadable, reason}}
    end
  end
end
