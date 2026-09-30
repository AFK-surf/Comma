defmodule SalixIM.SlackBotIdentityBackfillTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Salix.Slack.BackfillBotIds
  alias SalixStore.Keys

  @connect_prefix Keys.ctl_im_connects_all_prefix()

  defmodule MockSlackAPI do
    use Plug.Builder

    plug(:dispatch)

    defp dispatch(conn, _opts) do
      response =
        case get_req_header(conn, "authorization") do
          ["Bearer xoxb-connect-1"] ->
            %{
              "ok" => true,
              "bot_id" => "B-connect-1",
              "user_id" => "U-connect-1",
              "user" => "connect-1-bot",
              "team_id" => "T-connect-1"
            }

          _ ->
            %{"ok" => false, "error" => "invalid_auth"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_shell = Mix.shell()
    previous_slack_api_base_url = Application.get_env(:salix_im, :slack_api_base_url)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Mix.Task.run("app.start")

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)
      restore_env(:salix_im, :slack_api_base_url, previous_slack_api_base_url)
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "candidate pages bound reads and resume after the last scanned connect" do
    seeded =
      for index <- 1..5 do
        seed_connect("group-a", "connect-#{index}")
      end

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok,
            %{
              candidates: first_candidates,
              scanned_count: 2,
              next_cursor: first_cursor,
              scan_complete: false
            }} = SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(2, nil)

    assert Enum.map(first_candidates, & &1["connect_id"]) == ["connect-1", "connect-2"]
    assert is_binary(first_cursor)

    assert [
             {:list, @connect_prefix, first_list_opts},
             {:get, first_key},
             {:get, second_key}
           ] = SalixStore.S3.Fake.read_log()

    assert first_list_opts[:max_keys] == 2
    refute Keyword.has_key?(first_list_opts, :start_after)
    assert first_key == elem(Enum.at(seeded, 0), 0)
    assert second_key == elem(Enum.at(seeded, 1), 0)

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok,
            %{
              candidates: second_candidates,
              scanned_count: 2,
              next_cursor: second_cursor,
              scan_complete: false
            }} =
             SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(2, first_cursor)

    assert Enum.map(second_candidates, & &1["connect_id"]) == ["connect-3", "connect-4"]
    assert is_binary(second_cursor)

    assert [
             {:list, @connect_prefix, second_list_opts},
             {:get, third_key},
             {:get, fourth_key}
           ] = SalixStore.S3.Fake.read_log()

    assert second_list_opts[:max_keys] == 2
    assert second_list_opts[:start_after] == second_key
    assert third_key == elem(Enum.at(seeded, 2), 0)
    assert fourth_key == elem(Enum.at(seeded, 3), 0)

    assert {:ok,
            %{
              candidates: [last_candidate],
              scanned_count: 1,
              next_cursor: nil,
              scan_complete: true
            }} =
             SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(
               2,
               second_cursor
             )

    assert last_candidate["connect_id"] == "connect-5"
  end

  test "candidate scan rejects a foreign cursor without reading storage" do
    SalixStore.S3.Fake.reset_read_log()

    cursors = [
      "not-versioned",
      "v1.not-base64!",
      "v1." <> Base.url_encode64("foreign/record.json", padding: false),
      "v1." <> Base.url_encode64("ctl/other/record.json", padding: false),
      "v1." <> Base.url_encode64(@connect_prefix <> "not-a-connect.json", padding: false)
    ]

    for cursor <- cursors do
      assert {:error, :invalid_slack_bot_identity_backfill_cursor} =
               SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(10, cursor)
    end

    assert SalixStore.S3.Fake.read_log() == []
  end

  test "an ineligible page still returns the cursor for a later candidate" do
    seed_connect("group-a", "connect-1", %{
      "bot_id" => "B-resolved",
      "bot_user_id" => "U-resolved",
      "bot_username" => "resolved-bot"
    })

    seed_connect("group-a", "connect-2", %{"disabled_at" => 1})
    seed_connect("group-a", "connect-3")

    assert {:ok,
            %{
              candidates: [],
              scanned_count: 2,
              next_cursor: cursor,
              scan_complete: false
            }} = SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(2, nil)

    assert {:ok,
            %{
              candidates: [candidate],
              scanned_count: 1,
              next_cursor: nil,
              scan_complete: true
            }} = SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(2, cursor)

    assert candidate["connect_id"] == "connect-3"
  end

  test "task fails instead of reporting completion when the candidate list is unavailable" do
    SalixStore.S3.Fake.set_fault({:fail, 503, :list, @connect_prefix})

    assert_raise Mix.Error, ~r/candidate scan failed.*503/i, fn ->
      BackfillBotIds.run(["--apply", "--limit", "1"])
    end

    assert receive_info_messages_until_quiet() == []
  end

  test "dry run reports the cursor needed to inspect the next bounded page" do
    for index <- 1..3, do: seed_connect("group-a", "connect-#{index}")

    BackfillBotIds.run(["--limit", "2"])

    messages = receive_info_messages(3)
    assert Enum.count(messages, &String.starts_with?(&1, "would backfill")) == 2

    summary = List.last(messages)
    assert summary =~ "scanned 2"
    assert summary =~ "--cursor v1."
    refute summary =~ "scan complete"
    refute_receive {:mix_shell, :info, [_message]}
  end

  test "task fails instead of omitting an unreadable candidate" do
    {key, _connect} = seed_connect("group-a", "connect-unavailable")
    SalixStore.S3.Fake.set_fault({:fail, 503, :get, key})

    assert_raise Mix.Error, ~r/candidate scan failed.*connect-unavailable.*503/i, fn ->
      BackfillBotIds.run(["--apply", "--limit", "1"])
    end

    assert receive_info_messages_until_quiet() == []

    stored = SalixStore.S3.Fake.dump() |> Map.fetch!(key) |> Map.fetch!(:body) |> Jason.decode!()
    refute Map.has_key?(stored, "bot_id")
  end

  test "candidate scan rejects a connect whose body identity does not match its key" do
    {key, _connect} =
      seed_connect("group-a", "connect-key", %{"connect_id" => "connect-body"})

    assert {:error,
            {:slack_bot_identity_backfill_connect_unavailable, ^key, :invalid_record_identity}} =
             SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(1)
  end

  test "apply failure does not advance the page cursor after an earlier success" do
    {first_key, _first} = seed_connect("group-a", "connect-1")
    {second_key, _second} = seed_connect("group-a", "connect-2")
    port = free_port()
    start_supervised!({Bandit, plug: MockSlackAPI, port: port})
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    error =
      assert_raise Mix.Error, ~r/backfill failed.*connect-2.*invalid_auth/i, fn ->
        BackfillBotIds.run(["--apply", "--limit", "2"])
      end

    assert Exception.message(error) =~ "retry this page with --apply --limit 2"
    refute Exception.message(error) =~ "--cursor"

    messages = receive_info_messages_until_quiet()
    assert messages == ["backfilled connect=connect-1 workspace=T-connect-1"]
    refute Enum.any?(messages, &(&1 =~ "scan complete" or &1 =~ "--cursor"))

    dump = SalixStore.S3.Fake.dump()
    first = dump |> Map.fetch!(first_key) |> Map.fetch!(:body) |> Jason.decode!()
    second = dump |> Map.fetch!(second_key) |> Map.fetch!(:body) |> Jason.decode!()
    assert first["bot_id"] == "B-connect-1"
    assert first["bot_username"] == "connect-1-bot"
    refute Map.has_key?(second, "bot_id")
  end

  defp seed_connect(group_id, connect_id, attrs \\ %{}) do
    now = System.system_time(:millisecond)

    connect =
      Map.merge(
        %{
          "connect_id" => connect_id,
          "group_id" => group_id,
          "provider" => "slack",
          "bot_token" => "xoxb-#{connect_id}",
          "bot_user_id" => "U-#{connect_id}",
          "workspace_id" => "T-#{connect_id}",
          "oauth_completed_at" => now,
          "created_at" => now,
          "updated_at" => now
        },
        attrs
      )

    key = Keys.ctl_im_connect(group_id, connect_id)
    assert {:ok, ^connect} = SalixStore.CasRecord.create(key, connect)
    {key, connect}
  end

  defp receive_info_messages(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:mix_shell, :info, [message]}
      message
    end)
  end

  defp receive_info_messages_until_quiet(messages \\ []) do
    receive do
      {:mix_shell, :info, [message]} -> receive_info_messages_until_quiet([message | messages])
    after
      20 -> Enum.reverse(messages)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
