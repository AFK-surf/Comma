defmodule Comma.Stations.Notices do
  @moduledoc """
  Station notices pushed to people (contract §6). A notice has still.fail's
  shape (`station/src/cloud/notify.ts`): `{to, kind, session, thread, title, by,
  text, at}`. Recipients are resolved by email among the active members of the
  Comma Workspace that is the station's Group; unknown emails are ignored. Delivery reuses the
  Auth Session-owned APNs `device` addresses (`Comma.Notifications`), each
  address once per notice. One request is bounded: 50 notices, 20 recipients
  per notice, 200 pushes, eight concurrent APNs sends.
  """

  alias Comma.Accounts.Email
  alias Comma.{Notifications, Stations}

  @max_notices 50
  @max_to 20
  @max_pushes 200
  @max_text 140
  @concurrency 8

  def deliver(station_id, %{"notices" => notices}) when is_list(notices) do
    started = SystemsClock.monotonic_time()

    result =
      with {:ok, station} <- Stations.active_station(station_id) do
        notices = notices |> Enum.take(@max_notices) |> Enum.flat_map(&parse/1)
        emails = notices |> Enum.flat_map(& &1.to) |> Enum.uniq()

        # Recipients are Comma accounts: a Group that is no Comma Workspace has none.
        with {workspace_id, users} <-
               Stations.workspace_members_by_email(station.tenant_id, station.group_id, emails) do
          push(notices, users, station.id, workspace_id)
        end

        {:ok, %{}}
      end

    CommaProduct.Telemetry.emit_operation(
      :station_notify,
      if(match?({:ok, _}, result), do: :ok, else: :not_found),
      SystemsClock.monotonic_time() - started
    )

    result
  end

  def deliver(_station_id, _body), do: {:error, :invalid_request}

  defp push(notices, users, station_id, workspace_id) do
    targets =
      users
      |> Map.values()
      |> Notifications.station_notice_targets()
      |> Enum.group_by(fn {user_id, _target} -> user_id end, fn {_, target} -> target end)

    notices
    |> Enum.flat_map(fn notice ->
      notice.to
      |> Enum.flat_map(&Map.get(targets, Map.get(users, &1), []))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&{&1, payload(notice, &1, station_id, workspace_id)})
    end)
    |> Enum.take(@max_pushes)
    |> SystemsClock.async_stream(
      fn {target, payload} -> Notifications.deliver_station_notice(target, payload) end,
      max_concurrency: @concurrency,
      timeout: 10_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp parse(%{"to" => to, "kind" => kind, "session" => session, "text" => text} = n)
       when is_list(to) and is_binary(kind) and is_binary(session) and is_binary(text) do
    recipients =
      to
      |> Enum.flat_map(fn email ->
        case Email.normalize(email) do
          {:ok, normalized} -> [normalized]
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.take(@max_to)

    if recipients != [] and Regex.match?(~r/\A[a-z_]{1,32}\z/, kind) and session != "" and
         byte_size(session) <= 512 do
      [
        %{
          to: recipients,
          kind: kind,
          session: session,
          thread: if(is_integer(n["thread"]), do: n["thread"]),
          title: if(is_binary(n["title"]), do: n["title"], else: ""),
          by: if(is_binary(n["by"]) and n["by"] != "", do: n["by"]),
          text: text,
          at: if(is_integer(n["at"]), do: n["at"], else: SystemsClock.system_time(:second))
        }
      ]
    else
      []
    end
  end

  defp parse(_notice), do: []

  defp payload(notice, target, station_id, workspace_id) do
    title = line(notice.title)

    %{
      "aps" => %{
        "alert" => %{
          "title" => if(title == "", do: "Comma", else: title),
          "body" => body(notice, target.locale)
        },
        "sound" => "default",
        "thread-id" => "station:" <> station_id <> "/" <> notice.session
      },
      # Opaque routing correlation only; clients recheck authority with the station.
      "type" => "station_notice",
      "kind" => notice.kind,
      "workspace_id" => workspace_id,
      "station_id" => station_id,
      "station_session" => notice.session,
      "thread" => notice.thread,
      "at" => notice.at
    }
  end

  defp body(%{kind: "block", text: text}, "zh-Hans"), do: line("需要处理 · " <> text)
  defp body(%{kind: "block", text: text}, _), do: line("Needs you · " <> text)
  defp body(%{kind: "failed", text: text}, "zh-Hans"), do: line("出错了 · " <> text)
  defp body(%{kind: "failed", text: text}, _), do: line("Failed · " <> text)
  defp body(%{by: by, text: text}, _) when is_binary(by), do: line(by <> ": " <> text)
  defp body(%{text: text}, _), do: line(text)

  # One line, at most 140 characters, an ellipsis ending one cut short.
  defp line(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= @max_text,
      do: text,
      else: String.slice(text, 0, @max_text - 1) |> String.trim_trailing() |> Kernel.<>("…")
  end
end
