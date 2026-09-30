defmodule AlertRouter.Slack.MessageMarker do
  @moduledoc """
  Bot-token-compatible identity markers embedded in top-level Block Kit IDs.

  Slack can return blocks through `conversations.history` and
  `conversations.replies`, so delivery reconciliation does not depend on
  message-metadata scopes or schemas. Each root revision gets a distinct
  marker, as required for a message updated in place.
  """

  @root ~r/\Aar-([a-z0-9_-]{12})-r([1-9][0-9]*)-root\z/
  @timeline ~r/\Aar-([a-z0-9_-]{12})-r([1-9][0-9]*)-timeline-([a-z0-9_-]{12})\z/

  @type identity ::
          %{kind: :root, incident_id: String.t(), render_revision: pos_integer()}
          | %{
              kind: :timeline,
              incident_id: String.t(),
              render_revision: pos_integer(),
              event_id: String.t()
            }

  @spec root(String.t(), pos_integer()) :: String.t()
  def root(incident_id, revision), do: "ar-#{incident_id}-r#{revision}-root"

  @spec timeline(String.t(), pos_integer(), String.t()) :: String.t()
  def timeline(incident_id, revision, event_id),
    do: "ar-#{incident_id}-r#{revision}-timeline-#{event_id}"

  @spec identify(map()) :: identity() | nil
  def identify(%{"blocks" => blocks}) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{"block_id" => block_id} when is_binary(block_id) -> parse(block_id)
      _block -> nil
    end)
  end

  def identify(_message), do: nil

  @spec root?(map(), String.t(), pos_integer()) :: boolean()
  def root?(message, incident_id, revision) do
    identify(message) == %{kind: :root, incident_id: incident_id, render_revision: revision}
  end

  @spec timeline?(map(), String.t()) :: boolean()
  def timeline?(message, event_id) do
    case identify(message) do
      %{kind: :timeline, event_id: ^event_id} -> true
      _identity -> false
    end
  end

  defp parse(block_id) do
    case Regex.run(@root, block_id, capture: :all_but_first) do
      [incident_id, revision] ->
        %{kind: :root, incident_id: incident_id, render_revision: String.to_integer(revision)}

      nil ->
        parse_timeline(block_id)
    end
  end

  defp parse_timeline(block_id) do
    case Regex.run(@timeline, block_id, capture: :all_but_first) do
      [incident_id, revision, event_id] ->
        %{
          kind: :timeline,
          incident_id: incident_id,
          render_revision: String.to_integer(revision),
          event_id: event_id
        }

      nil ->
        nil
    end
  end
end
