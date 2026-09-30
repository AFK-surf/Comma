defmodule CommaWeb.TelegramWebhook do
  @moduledoc "Explicit, retryable release operation for the Comma Telegram webhook."

  alias CommaWeb.TelegramBot

  def plan do
    if TelegramBot.configured?() do
      {:ok,
       %{
         "allowed_updates" => ["message", "callback_query"],
         "bot_username" => TelegramBot.bot_username(),
         "webhook_url" => TelegramBot.webhook_url()
       }}
    else
      {:error, :telegram_unavailable}
    end
  end

  def apply(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    with {:ok, plan} <- plan() do
      if dry_run? do
        {:ok, Map.put(plan, "dry_run", true)}
      else
        with {:ok, bot} <- TelegramBot.get_me(),
             :ok <- verify_bot_username(bot),
             {:ok, true} <-
               TelegramBot.set_webhook(
                 TelegramBot.webhook_url(),
                 telegram_config()[:webhook_secret]
               ),
             {:ok, info} <- TelegramBot.get_webhook_info(),
             true <- info["url"] == TelegramBot.webhook_url(),
             true <- Enum.all?(plan["allowed_updates"], &(&1 in (info["allowed_updates"] || []))) do
          {:ok,
           Map.merge(plan, %{
             "dry_run" => false,
             "has_custom_certificate" => info["has_custom_certificate"] == true,
             "pending_update_count" => info["pending_update_count"] || 0
           })}
        else
          false -> {:error, :telegram_webhook_drift}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  defp verify_bot_username(bot) when is_map(bot) do
    if normalize_username(bot["username"]) == TelegramBot.bot_username(),
      do: :ok,
      else: {:error, :telegram_bot_identity_mismatch}
  end

  defp verify_bot_username(_bot), do: {:error, :telegram_bot_identity_mismatch}

  defp normalize_username(nil), do: ""
  defp normalize_username(value), do: value |> to_string() |> String.trim_leading("@")
  defp telegram_config, do: Application.get_env(:comma_web, :telegram, [])
end
