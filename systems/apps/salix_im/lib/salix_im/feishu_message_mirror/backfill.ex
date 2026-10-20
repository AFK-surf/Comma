defmodule SalixIM.FeishuMessageMirror.Backfill do
  @moduledoc """
  One bounded history pass over one Feishu app installation.

  The live callback path owns everything after a container's first page; this
  walks older history, newest first, one `/im/v1/messages` page at a time.
  Containers are a chat's top-level history and each thread found on it, and
  every one has a watermark in `SalixStore.FeishuMirrorBackfillLedger`.

  A pass:

    1. takes up to `page_budget` unfinished containers, least recently touched
       first. When none is left it lists the app's chats first (`/im/v1/chats`),
       so chats the bot joined since the last pass are picked up;
    2. fetches one page per container, paced by `pace_ms`, writes the rows
       through `SalixIM.FeishuMessageMirror.write_batch/1`, records the threads
       it saw, and only then commits the page. A write failure stops the pass
       without committing; a page fetch failure drops the container's page
       token so the next attempt restarts from its watermark.

  It reports `:more` while any container is unfinished, `:retry` when a page
  failed, and `:idle` when every container reached the oldest history Feishu
  returns. Re-walking a page is harmless: rows are versioned by the message's
  own state.
  """

  require Logger

  alias SalixIM.FeishuMessageMirror
  alias SalixIM.FeishuMessageMirror.Row
  alias SalixStore.FeishuMirrorBackfillLedger

  @default_page_budget 20
  @default_max_chat_pages 50

  @type outcome :: :more | :idle | :retry

  defmodule FeishuReader do
    @moduledoc false
    alias SalixIM.Provider.Feishu.API

    def list_chats(connect, page_token) do
      API.get(connect, "/im/v1/chats", %{page_size: 100, page_token: page_token})
    end

    def list_messages(connect, container, page_token, end_time) do
      API.get(connect, "/im/v1/messages", %{
        container_id_type: container["container_type"],
        container_id: container["container_id"],
        sort_type: "ByCreateTimeDesc",
        page_size: 50,
        page_token: page_token,
        end_time: end_time,
        with_sender_name: true
      })
    end
  end

  @doc "Runs one pass. See the moduledoc for the outcomes."
  @spec run_pass(map(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run_pass(connect, opts \\ []) do
    scope = %{"tenant_id" => connect["tenant_id"], "app_id" => connect["app_id"]}
    ledger = opts[:ledger] || FeishuMirrorBackfillLedger
    budget = opts[:page_budget] || @default_page_budget

    with {:ok, containers} <- containers(connect, scope, ledger, budget, opts) do
      walk(connect, scope, containers, ledger, opts, {false, false})
    end
  end

  defp containers(connect, scope, ledger, budget, opts) do
    case ledger.next_containers(scope, budget) do
      {:ok, []} ->
        with :ok <- discover_chats(connect, scope, ledger, opts) do
          ledger.next_containers(scope, budget)
        end

      other ->
        other
    end
  end

  defp discover_chats(connect, scope, ledger, opts) do
    max_pages = opts[:max_chat_pages] || @default_max_chat_pages

    Enum.reduce_while(1..max_pages, nil, fn _page, token ->
      pace(opts)

      with {:ok, data} <- reader(opts).list_chats(connect, token),
           :ok <-
             ledger.upsert_containers(
               scope,
               for %{"chat_id" => chat_id} when is_binary(chat_id) and chat_id != "" <-
                     List.wrap(data["items"]) do
                 %{"container_type" => "chat", "container_id" => chat_id, "chat_id" => chat_id}
               end
             ) do
        case {data["has_more"], data["page_token"]} do
          {true, next} when is_binary(next) and next != "" -> {:cont, next}
          _done -> {:halt, :ok}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      # Ran out of pages with more to list: the rest is found next pass.
      token when is_binary(token) -> :ok
      result -> result
    end
  end

  # `acc` is {failed?, unfinished?}: any failed page makes the pass `:retry`,
  # any container left unfinished makes it `:more`.
  defp walk(_connect, _scope, [], _ledger, _opts, {true, _unfinished?}), do: {:ok, :retry}
  defp walk(_connect, _scope, [], _ledger, _opts, {false, true}), do: {:ok, :more}

  defp walk(_connect, scope, [], ledger, _opts, {false, false}) do
    case ledger.next_containers(scope, 1) do
      {:ok, []} -> {:ok, :idle}
      {:ok, [_ | _]} -> {:ok, :more}
      {:error, _reason} = error -> error
    end
  end

  defp walk(connect, scope, [container | rest], ledger, opts, {failed?, unfinished?}) do
    pace(opts)
    observed_us = SystemsClock.system_time(:microsecond)

    case fetch(connect, container, opts) do
      {:ok, data} ->
        case land_page(connect, scope, container, data, observed_us, ledger, opts) do
          {:ok, exhausted?} ->
            walk(connect, scope, rest, ledger, opts, {failed?, unfinished? or not exhausted?})

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("feishu mirror backfill page failed: #{inspect(reason)}")
        _ = ledger.fail_container(scope, container, reason)
        walk(connect, scope, rest, ledger, opts, {true, true})
    end
  end

  defp fetch(connect, container, opts) do
    token = blank_nil(container["page_token"])

    # Feishu accepts end_time in whole seconds. Resume at the next second
    # so messages below the millisecond watermark are not skipped.
    end_time =
      if is_nil(token) and container["container_type"] == "chat" and
           is_integer(container["indexed_from_us"]),
         do: Integer.to_string(div(container["indexed_from_us"], 1_000_000) + 1)

    reader(opts).list_messages(connect, container, token, end_time)
  end

  defp land_page(connect, scope, container, data, observed_us, ledger, opts) do
    items = Enum.filter(List.wrap(data["items"]), &is_map/1)

    rows =
      for item <- items, {:ok, row} <- [Row.from_history(connect, item, observed_us)], do: row

    threads =
      if container["container_type"] == "chat" do
        for %{"thread_id" => thread_id, "chat_id" => chat_id} <- rows, thread_id != "" do
          %{"container_type" => "thread", "container_id" => thread_id, "chat_id" => chat_id}
        end
      else
        []
      end

    next = if data["has_more"] == true, do: blank_nil(data["page_token"])
    exhausted? = is_nil(next)

    oldest_us =
      rows
      |> Enum.map(& &1["create_time_us"])
      |> Enum.filter(&(&1 > 0))
      |> Enum.min(fn -> nil end)

    with :ok <- writer(opts).write_batch(rows),
         :ok <- ledger.upsert_containers(scope, threads),
         :ok <-
           ledger.commit_page(scope, container, %{
             "oldest_us" => oldest_us,
             "observed_us" => observed_us,
             "page_token" => next,
             "exhausted" => exhausted?
           }) do
      {:ok, exhausted?}
    end
  end

  defp pace(opts) do
    case opts[:pace_ms] || 0 do
      ms when is_integer(ms) and ms > 0 -> (opts[:sleep] || (&SystemsClock.sleep/1)).(ms)
      _ -> :ok
    end
  end

  defp reader(opts), do: opts[:reader] || FeishuReader
  defp writer(opts), do: opts[:writer] || FeishuMessageMirror

  defp blank_nil(value) when is_binary(value) and value != "", do: value
  defp blank_nil(_value), do: nil
end
