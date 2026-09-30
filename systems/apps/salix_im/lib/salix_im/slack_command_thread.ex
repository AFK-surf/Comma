defmodule SalixIM.SlackCommandThread do
  @moduledoc """
  Publishes the source thread before a slash command enters the Router.

  A durable receipt fences concurrent callbacks and preserves the returned Slack
  timestamp across admission retries. An uncertain write is never blindly sent
  again: Slack does not provide an exactly-once postMessage contract. A crash or
  lost response between publication and receipt persistence needs inspection,
  not a second root message. Only a definitive provider rejection is retryable.
  No prompt, token, or response URL is stored in the receipt.
  """

  alias SalixIM.Provider.Slack.API
  alias SalixStore.{CasRecord, Keys}

  @post_timeout_ms 1_000

  # Bound the encoded text too: escaping can expand a short input beyond Slack's
  # message limit. The original prompt still enters the Router unchanged.
  def prompt_within_limit?(text), do: length(String.codepoints(escape_prompt(text))) <= 39_000

  defp escape_prompt(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def ensure(connect, params, remaining_ms) do
    key =
      Keys.ctl_im_slack_command_thread(connect["connect_id"], params["trigger_id"])

    owner = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    fingerprint =
      [
        connect["app_id"],
        connect["bot_user_id"],
        params["team_id"],
        params["channel_id"],
        params["user_id"],
        params["command"],
        params["text"]
      ]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    claim = %{
      "schema" => "slack-command-thread.v1",
      "fingerprint" => fingerprint,
      "owner" => owner,
      "state" => "posting",
      "created_at" => System.system_time(:millisecond)
    }

    with true <-
           remaining_ms.() > 0 and is_binary(connect["bot_user_id"]) and
             connect["bot_user_id"] != "",
         {:ok, receipt} <-
           CasRecord.update(key, fn
             nil -> claim
             %{"fingerprint" => ^fingerprint, "state" => "rejected"} -> claim
             %{"fingerprint" => ^fingerprint} = existing -> {:unchanged, existing}
             _ -> {:error, :command_thread_conflict}
           end) do
      case receipt do
        %{"state" => "posted", "ts" => ts} ->
          {:ok, ts}

        %{"owner" => ^owner, "state" => "posting"} ->
          publish(key, claim, connect, params, remaining_ms)

        _ ->
          {:error, :command_thread_pending}
      end
    else
      false -> {:error, :command_thread_failed}
      {:error, _} -> {:error, :command_thread_pending}
    end
  end

  defp publish(key, claim, connect, params, remaining_ms) do
    timeout = min(@post_timeout_ms, remaining_ms.())

    if timeout <= 0 do
      settle(key, claim, %{"state" => "rejected"})
      {:error, :command_thread_failed}
    else
      # Use the existing Slack Web API adapter: this adds no new HTTP/signing
      # implementation or SDK. Preserve the user's prompt, not the worker prefix.
      response =
        API.request_form(
          connect["bot_token"],
          "chat.postMessage",
          [
            channel: params["channel_id"],
            text:
              "<@#{params["user_id"]}> : <@#{connect["bot_user_id"]}> " <>
                escape_prompt(params["text"]),
            parse: "none",
            unfurl_links: false,
            unfurl_media: false
          ],
          timeout_ms: timeout,
          pool_retries: 0
        )

      channel = params["channel_id"]

      case response do
        %{"channel" => ^channel, "ts" => ts} when is_binary(ts) and ts != "" ->
          case settle(key, claim, %{"state" => "posted", "ts" => ts}) do
            {:ok, _} -> {:ok, ts}
            _ -> {:error, :command_thread_pending}
          end

        _ ->
          {:error, :command_thread_pending}
      end
    end
  rescue
    error in API.Error ->
      # ok:false and HTTP 429 explicitly reject the write. A timeout/5xx may
      # have posted it already and must retain the non-retryable reservation.
      if match?(%{"ok" => false}, error.body) or error.status == 429 do
        settle(key, claim, %{"state" => "rejected"})
        {:error, :command_thread_failed}
      else
        {:error, :command_thread_pending}
      end
  end

  defp settle(key, claim, attrs) do
    CasRecord.update(
      key,
      fn
        ^claim -> Map.merge(claim, attrs)
        current -> {:unchanged, current}
      end,
      create: false
    )
  end
end
