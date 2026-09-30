defmodule SalixIM.Triage.SourcePresentation do
  @moduledoc """
  Optional display names for one authorized Timeline page. The LiveView loads
  these off the render path. One request reads at most 20 exact receipts and
  resolves at most 20 distinct profiles, with four concurrent lookups and a
  one-second budget per lookup. There is no polling or retry loop. Names use
  the existing credential-scoped profile cache; missing names remain unknown.
  """

  alias SalixIM.Triage.SourceSpeakerLabels
  @mention ~r/<@([UW][A-Z0-9]{2,31})(?:\|[^>]*)?>/

  def read(group_id, receipt_refs, opts \\ [])

  def read(group_id, receipt_refs, opts)
      when is_binary(group_id) and is_list(receipt_refs) and length(receipt_refs) <= 20 do
    with true <- Enum.all?(receipt_refs, &(is_binary(&1) and byte_size(&1) in 1..2048)),
         {:ok, receipts} <-
           Keyword.get(opts, :receipts_fun, &SalixStore.TriageIntake.by_refs/2).(
             group_id,
             receipt_refs
           ) do
      requests =
        receipts
        |> Enum.flat_map(fn receipt ->
          event = receipt["triage_event"]
          actors = [event["actor_id"] | mentions(event["text"])]

          Enum.map(actors, fn actor ->
            key = {receipt["connect_id"], event["bucket"]["workspace_id"], actor}

            {key,
             %{
               "product_identity" => %{"project_salix_group_id" => group_id},
               "target" => %{
                 "connect_id" => receipt["connect_id"],
                 "connect_generation" => receipt["connect_generation"],
                 "workspace_id" => event["bucket"]["workspace_id"]
               },
               "source_messages" => [%{"actor_id" => actor, "actor_kind" => "human"}]
             }}
          end)
        end)
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.take(20)

      profile_fun = Keyword.get(opts, :profile_fun, &SourceSpeakerLabels.resolve/1)

      labels =
        requests
        |> Task.async_stream(
          fn {key, payload} -> {key, List.first(profile_fun.(payload))} end,
          max_concurrency: 4,
          timeout: Keyword.get(opts, :timeout, 1_000),
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {key, label}} when is_binary(label) and label != "" -> [{key, label}]
          _ -> []
        end)
        |> Map.new()

      {:ok,
       Map.new(receipts, fn receipt ->
         event = receipt["triage_event"]

         label = fn actor ->
           labels[{receipt["connect_id"], event["bucket"]["workspace_id"], actor}]
         end

         {receipt["receipt_ref"],
          %{
            speaker_label: label.(event["actor_id"]),
            mentions: Map.new(mentions(event["text"]), &{&1, label.(&1)})
          }}
       end)}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def read(_group, _refs, _opts), do: {:error, :invalid}

  defp mentions(text) when is_binary(text),
    do:
      @mention
      |> Regex.scan(String.slice(text, 0, 1024), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

  defp mentions(_), do: []
end
