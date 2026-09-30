defmodule SalixIM.Triage.ReadSourceContext do
  @moduledoc """
  Pure public read-locator projection from the exact Task delivery snapshot.

  No storage, routing or authorization is performed here. Product-owned refs
  stay private; the model receives only bounded Slack coordinates. This is the
  WorkerReadSources projection in `tla/salix/TriageRouterHandoff.tla`, not a
  new delivery transition or a promise to backfill already delivered inputs.
  """

  @max_sources 200
  @max_ref_bytes 256
  @source_pattern ~r"\Aslack://([A-Z0-9_]{1,64})/([A-Z0-9_]{1,64})/(channel|[0-9]{10}\.[0-9]{6})/([0-9]{10}\.[0-9]{6})\z"
  @unavailable "Read-only investigation sources: unavailable (unsupported or invalid source coordinates). Use authorized discovery; do not infer a source from unrelated context."

  def content(%{
        "conversation_kind" => "agent_task",
        "participant_role_label" => "worker",
        "conversation_source_refs" => %{"triage_source_refs" => refs}
      })
      when is_list(refs) do
    bounded = Enum.take(refs, @max_sources + 1)

    if length(bounded) > @max_sources do
      @unavailable
    else
      case project(bounded) do
        {:ok, []} ->
          @unavailable

        {:ok, sources} ->
          "Read-only investigation sources (model-only locators, not read permission or external reply authority): " <>
            Jason.encode!(%{"sources" => sources})

        :error ->
          @unavailable
      end
    end
  end

  def content(_delivery), do: ""

  defp project(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, sources} ->
      case coordinates(ref) do
        {:ok, source} -> {:cont, {:ok, [source | sources]}}
        :unsupported -> {:cont, {:ok, sources}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      :error -> :error
    end
  end

  defp coordinates(ref) when is_binary(ref) and byte_size(ref) <= @max_ref_bytes do
    case Regex.run(@source_pattern, ref) do
      [_, workspace, channel, scope, message_ts] ->
        source = %{
          "provider" => "slack",
          "workspace_id" => workspace,
          "channel_id" => channel,
          "message_ts" => message_ts,
          "source_ref" => ref
        }

        {:ok, if(scope == "channel", do: source, else: Map.put(source, "thread_ts", scope))}

      nil ->
        if String.starts_with?(ref, "slack://"), do: :error, else: :unsupported
    end
  end

  defp coordinates(_ref), do: :error
end
