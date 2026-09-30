defmodule SalixMeet.PreparationMarkdown do
  @moduledoc "Normalizes report links and disables report-authored provider mentions."

  # Research can quote Slack source links, but stored reports serve both Slack
  # and Calendar. Keep their representation in standard Markdown.
  @slack_link ~r/<(https?:\/\/[^\s<>|]+)\|([^<>\n]+)>/u
  @provider_reference ~r/<([@#!][^>\n]*)>/u

  def normalize(text) when is_binary(text) do
    text =
      Regex.replace(@slack_link, text, fn _, url, label ->
        "[" <> escape_label(label) <> "](<" <> url <> ">)"
      end)

    Regex.replace(@provider_reference, text, fn _, reference -> "‹" <> reference <> "›" end)
  end

  defp escape_label(label) do
    Regex.replace(~r/[\\\[\]`*_]/u, label, fn char -> "\\" <> char end)
  end
end
