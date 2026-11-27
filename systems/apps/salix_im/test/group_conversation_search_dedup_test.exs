defmodule SalixIM.GroupConversationSearchDedupTest do
  @moduledoc """
  Groups of one Tenant that each connect their own Feishu or Lark bot app (a
  different `app_id`) but share one group chat get each message of that chat
  once from `SalixIM.GroupConversationSearch.search/2`, for the lowest
  authorized `group_id`, and `read/2` of that hit reads through that Group's
  own app.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.GroupConversationSearch
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @test_pid_key :group_search_dedup_test_pid

  defmodule FakeMirrorNoop do
    @moduledoc false
    def record_batch(_rows), do: :ok
  end

  defmodule FakeReader do
    @moduledoc """
    One mirror index per `app_id`: both department apps hold the shared chat's
    message `om_same_1`, each holds a message of its own chat and a `p2p` row.
    """
    @apps %{
      "cli_dept_a" => "a",
      "cli_dept_b" => "b",
      "cli_lark_a" => "a",
      "cli_lark_b" => "b"
    }

    def search(%{"app_id" => app_id} = scope, opts) do
      chat_id = Keyword.get(opts, :chat_id)

      case SystemsRuntime.get_env(:salix_im, :group_search_dedup_test_pid) do
        pid when is_pid(pid) and is_binary(chat_id) ->
          SystemsRuntime.Proc.send(pid, {:mirror_read, scope, chat_id})

        _search ->
          :ok
      end

      rows =
        case Map.fetch(@apps, app_id) do
          {:ok, dept} -> rows(dept)
          :error -> []
        end

      before_us = Keyword.get(opts, :before_us)
      patterns = Keyword.get(opts, :patterns, [])

      matched =
        rows
        |> Enum.filter(&(is_nil(chat_id) or &1["chat_id"] == chat_id))
        |> Enum.filter(&(is_nil(before_us) or &1["create_time_us"] < before_us))
        |> Enum.filter(fn row ->
          Enum.all?(patterns, fn pat ->
            String.contains?(row["text"], String.trim(pat, "%"))
          end)
        end)
        |> Enum.sort_by(& &1["create_time_us"], :desc)

      {:ok, %{messages: matched, has_more?: false, next_cursor: nil}}
    end

    defp rows(dept) do
      [
        row("om_same_1", "oc_shared", "group", "budget review in the shared room", 1),
        row("om_only_#{dept}", "oc_#{dept}", "group", "budget plan of dept #{dept}", 2),
        row("om_dm_#{dept}", "oc_dm_#{dept}", "p2p", "budget secret of dept #{dept}", 3)
      ]
    end

    defp row(message_id, chat_id, chat_type, text, second) do
      %{
        "message_id" => message_id,
        "chat_id" => chat_id,
        "chat_type" => chat_type,
        "thread_id" => "",
        "actor_id" => "ou_1",
        "actor_label" => "Lin",
        "text" => text,
        "create_time_us" => 1_700_000_000_000_000 + second * 1_000_000
      }
    end
  end

  @env_keys [
    {:salix_store, :s3_backend},
    {:salix_im, :feishu_message_mirror_mod},
    {:salix_im, :feishu_mirror_reader_mod},
    {:salix_im, :lark_message_record_mod},
    {:salix_im, :lark_message_record_reader_mod},
    {:salix_im, @test_pid_key}
  ]

  setup do
    prev = Map.new(@env_keys, fn {app, key} -> {{app, key}, SystemsRuntime.get_env(app, key)} end)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    SystemsRuntime.put_env(:salix_im, :feishu_message_mirror_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :feishu_mirror_reader_mod, FakeReader)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_mod, FakeMirrorNoop)
    SystemsRuntime.put_env(:salix_im, :lark_message_record_reader_mod, FakeReader)
    SystemsRuntime.put_env(:salix_im, @test_pid_key, SystemsRuntime.Proc.self())
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    on_exit(fn ->
      Enum.each(prev, fn
        {{app, key}, nil} -> SystemsRuntime.delete_env(app, key)
        {{app, key}, value} -> SystemsRuntime.put_env(app, key, value)
      end)
    end)

    tenant_id = Ids.new_tenant_id()
    group_a = put_group!(tenant_id, "Dept A", [])
    group_b = put_group!(tenant_id, "Dept B", [])
    caller = put_group!(tenant_id, "Management", [group_a, group_b])

    put_connect!(tenant_id, group_a, "imc_feishu_a", "feishu", "cli_dept_a")
    put_connect!(tenant_id, group_b, "imc_feishu_b", "feishu", "cli_dept_b")
    put_connect!(tenant_id, group_a, "imc_lark_a", "lark", "cli_lark_a")
    put_connect!(tenant_id, group_b, "imc_lark_b", "lark", "cli_lark_b")

    first = Enum.min([group_a, group_b])

    apps = %{
      {group_a, "feishu"} => "cli_dept_a",
      {group_b, "feishu"} => "cli_dept_b",
      {group_a, "lark"} => "cli_lark_a",
      {group_b, "lark"} => "cli_lark_b"
    }

    %{caller: caller, group_a: group_a, group_b: group_b, first: first, apps: apps}
  end

  test "a shared Feishu/Lark chat's message is returned once across department apps and reads through the owning Group's app",
       %{caller: caller, group_a: group_a, group_b: group_b, first: first, apps: apps} do
    assert {:ok, %{"hits" => hits}} =
             GroupConversationSearch.search(caller, %{"query" => "budget"})

    for provider <- ["feishu", "lark"] do
      provider_hits = Enum.filter(hits, &(&1["source"] == provider))

      assert [shared] = Enum.filter(provider_hits, &(&1["chat_id"] == "oc_shared")),
             inspect(provider_hits)

      assert shared["group_id"] == first

      assert [%{"group_id" => ^group_a}] = Enum.filter(provider_hits, &(&1["chat_id"] == "oc_a"))
      assert [%{"group_id" => ^group_b}] = Enum.filter(provider_hits, &(&1["chat_id"] == "oc_b"))
      refute Enum.any?(provider_hits, &String.starts_with?(&1["chat_id"], "oc_dm_"))

      assert {:ok, read} = GroupConversationSearch.read(caller, %{"hit_id" => shared["hit_id"]})
      assert read["group_id"] == first
      assert read["chat_id"] == "oc_shared"
      assert [%{"message_id" => "om_same_1"}] = read["messages"]

      first_app = Map.fetch!(apps, {first, provider})
      assert_received {:mirror_read, %{"app_id" => ^first_app}, "oc_shared"}
      refute_received {:mirror_read, _scope, _chat_id}
    end
  end

  defp put_group!(tenant_id, name, search_group_ids) do
    group_id = Ids.new_group_id(tenant_id)

    {:ok, _created} =
      CasRecord.create(Keys.ctl_group(group_id), %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "name" => name,
        "router_conversation_id" => Ids.new_conversation_id(),
        "search_group_ids" => search_group_ids
      })

    group_id
  end

  defp put_connect!(tenant_id, group_id, connect_id, provider, app_id) do
    {:ok, _created} =
      CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
        "connect_id" => connect_id,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => provider,
        "app_id" => app_id
      })
  end
end
