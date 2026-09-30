defmodule CommaWeb.TelegramCommandSetup do
  @moduledoc "Explicit, repeatable private-chat command setup; never runs at application boot."

  alias CommaWeb.{TelegramBot, TelegramCommands}

  def apply(opts \\ []) do
    if TelegramBot.configured?() do
      plan = %{
        "bot_username" => TelegramBot.bot_username(),
        "scope" => %{"type" => "all_private_chats"},
        "commands" => Map.new(["", "en", "zh"], &{&1, TelegramCommands.menu(&1)}),
        "menu_button" => %{"type" => "commands"}
      }

      if Keyword.get(opts, :dry_run, true) do
        {:ok, Map.put(plan, "dry_run", true)}
      else
        with {:ok, bot} <- TelegramBot.get_me(),
             true <- bot["username"] == plan["bot_username"],
             :ok <- apply_commands(plan["commands"]),
             {:ok, true} <- TelegramBot.set_command_menu(),
             {:ok, %{"type" => "commands"}} <- TelegramBot.get_menu_button() do
          {:ok, Map.put(plan, "dry_run", false)}
        else
          false -> {:error, :telegram_bot_identity_mismatch}
          {:error, _reason} = error -> error
          _other -> {:error, :telegram_command_setup_drift}
        end
      end
    else
      {:error, :telegram_unavailable}
    end
  end

  defp apply_commands(catalog) do
    Enum.reduce_while(["", "en", "zh"], :ok, fn language, :ok ->
      commands = Map.fetch!(catalog, language)

      with {:ok, true} <- TelegramBot.set_commands(commands, language),
           {:ok, ^commands} <- TelegramBot.get_commands(language) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, :telegram_command_setup_drift}}
      end
    end)
  end
end
