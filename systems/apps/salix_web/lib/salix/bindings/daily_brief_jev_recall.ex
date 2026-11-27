defmodule Salix.Bindings.DailyBriefJevRecall do
  @moduledoc """
  Scores P2 Daily Brief candidate messages via `SalixAgent.Decide` (`Jev`) so
  high-signal team updates (decisions, blockers, deliverables, releases) can be
  recalled into P1 without sending low-signal noise.
  """

  alias Salix.Control.Groups
  alias SalixAgent.{Decide, RouterDecision}
  alias SalixStore.Ids

  @max_messages 24
  @batch_size 8
  @max_text_chars 300
  @max_payload_bytes 11_000
  @admission_timeout_ms 3_000

  @spec score(map()) :: {:ok, map()} | {:error, term()}
  def score(%{group_id: group_id, messages: messages})
      when is_binary(group_id) and group_id != "" and is_list(messages) do
    do_score(group_id, messages)
  end

  def score(%{"group_id" => group_id, "messages" => messages})
      when is_binary(group_id) and group_id != "" and is_list(messages) do
    do_score(group_id, messages)
  end

  def score(_request), do: {:ok, %{}}

  defp do_score(_group_id, []), do: {:ok, %{}}

  defp do_score(group_id, messages) do
    with {:ok, _config} <- Decide.config(),
         {:ok, ctx} <- build_context(group_id) do
      batches =
        messages
        |> Enum.take(@max_messages)
        |> Enum.chunk_every(@batch_size)

      scores =
        Enum.reduce(batches, %{}, fn batch, acc ->
          Map.merge(acc, score_batch(batch, ctx))
        end)

      {:ok, scores}
    else
      _ -> {:ok, %{}}
    end
  rescue
    _ -> {:ok, %{}}
  catch
    :exit, _ -> {:ok, %{}}
  end

  defp build_context(group_id) do
    with {:ok, %{"agent_id" => agent_id}, session_id}
         when is_binary(agent_id) and agent_id != "" and is_binary(session_id) and
                session_id != "" <- RouterDecision.router(group_id),
         tenant_id when is_binary(tenant_id) and tenant_id != "" <-
           Ids.tenant_id_from_group!(group_id),
         {:ok, group} <- Groups.get(group_id, tenant_id) do
      billing_context =
        case group["billing_owner"] do
          %{} = billing -> billing
          _ -> %{}
        end

      {:ok,
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         agent_id: agent_id,
         session_id: session_id,
         billing_context: billing_context
       }}
    else
      _ -> {:error, :context_unavailable}
    end
  end

  defp score_batch(batch, ctx) do
    case build_payload(batch, @max_text_chars) do
      {:ok, args} ->
        deadline = SystemsClock.monotonic_time(:millisecond) + @admission_timeout_ms

        case Decide.system_call(
               args,
               ctx,
               entrypoint: "bft_daily_brief_jev_recall",
               admission_deadline: deadline
             ) do
          {:ok, %{"answers" => answers}} when is_map(answers) ->
            batch
            |> Enum.with_index()
            |> Enum.reduce(%{}, fn {msg, idx}, acc ->
              channel_id = field(msg, :channel_id)
              ts = field(msg, :ts)

              case Map.get(answers, "m#{idx}") do
                %{} = ans when is_binary(channel_id) and is_binary(ts) ->
                  case get_in(ans, ["probabilities_bp", "promote"]) do
                    bp when is_integer(bp) -> Map.put(acc, {channel_id, ts}, bp)
                    _ -> acc
                  end

                _ ->
                  acc
              end
            end)

          _ ->
            %{}
        end

      :too_large when length(batch) > 1 ->
        mid = div(length(batch), 2)
        {left, right} = Enum.split(batch, mid)
        Map.merge(score_batch(left, ctx), score_batch(right, ctx))

      :too_large ->
        %{}
    end
  end

  defp build_payload(batch, text_limit) do
    indexed = Enum.with_index(batch)

    items =
      Enum.map(indexed, fn {msg, idx} ->
        entry = %{
          "key" => "m#{idx}",
          "text" => String.slice(to_string(field(msg, :text) || ""), 0, text_limit)
        }

        case field(msg, :actor_label) do
          label when is_binary(label) and label != "" ->
            Map.put(entry, "actor", String.slice(label, 0, 64))

          _ ->
            entry
        end
      end)

    questions =
      Map.new(indexed, fn {_msg, idx} ->
        key = "m#{idx}"

        {key,
         %{
           "type" => "choice",
           "instructions" =>
             "Decide whether team message #{key} should be promoted into today's Daily Brief.",
           "criteria" => %{
             "promote" =>
               "Contains a concrete decision, blocker, deliverable, release, or actionable update for team members today",
             "drop" => "Casual chatter, social noise, or unactionable background message"
           }
         }}
      end)

    args = %{"state" => %{"messages" => items}, "questions" => questions}

    cond do
      byte_size(Jason.encode!(args)) <= @max_payload_bytes ->
        {:ok, args}

      text_limit > 0 ->
        build_payload(batch, div(text_limit, 2))

      true ->
        :too_large
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_other, _key), do: nil
end
