defmodule SalixAgent.LanBinaryTest do
  @moduledoc """
  `device.lan_request` with `response: "binary"` and `auth.type:
  "http_digest"`: a camera snapshot fetched through a gateway that answers
  in chunks, stored as a workspace file and shown to the model.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, DeviceSecrets, HttpDigestAuth, ImageRefs}
  alias SalixAgent.Tools.LanGateway
  alias SalixStore.S3

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>
  @password "Pa55:w0rd!"
  @snapshot "http://192.168.5.33/stream/snapshot.jpg?channel=1"

  defmodule TemplateMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id), do: SalixAgent.AgentModel.resolve_media_for_agent(agent_id)
  end

  # A gateway in front of a camera whose snapshot needs Digest: the first
  # request draws a challenge, the answered one returns the picture as the
  # connector socket hands it over after reassembly.
  defmodule Dispatch do
    def get_device(_agent_id, _device_id), do: Process.get(:lan_device)

    def request(_agent_id, _target, method, params) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:request, method, params})

      case Process.get(:refusal) do
        nil -> respond(params)
        refusal -> {:error, refusal}
      end
    end

    defp respond(params) do
      case get_in(params, ["headers", "Authorization"]) do
        nil ->
          {:ok,
           %{
             "status" => 401,
             "headers" => %{
               "WWW-Authenticate" =>
                 Process.get(:challenges, [
                   ~s(Digest realm="TP-LINK IP-Camera", qop="auth", nonce="abc123", opaque="xyz")
                 ])
             },
             "body" => "",
             "body_bytes" => 0,
             "truncated" => false
           }}

        _authorization ->
          {:ok,
           %{
             "status" => 200,
             "headers" => %{"Content-Type" => ["image/png"]},
             "body_encoding" => "binary",
             "body_binary" => Process.get(:snapshot),
             "body_bytes" => byte_size(Process.get(:snapshot)),
             "truncated" => false,
             "final_url" => params["url"],
             "method" => "GET"
           }}
      end
    end
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      dispatch: SystemsRuntime.get_env(:salix_agent, :env_dispatch),
      resolver: SystemsRuntime.get_env(:salix_agent, :media_resolver)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, Dispatch)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, TemplateMediaResolver)

    on_exit(fn ->
      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous.s3},
            {:salix_agent, :env_dispatch, previous.dispatch},
            {:salix_agent, :media_resolver, previous.resolver}
          ] do
        if value,
          do: SystemsRuntime.put_env(app, key, value),
          else: SystemsRuntime.delete_env(app, key)
      end
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent, %{"supports_images" => true})
    group = SalixStore.Ids.group_id_from_agent!(agent)

    {:ok, _, :created} =
      DeviceSecrets.save(group, %{
        "kind" => "onvif_password",
        "name" => "office-camera",
        "value" => @password
      })

    Process.put(:snapshot, @png)

    gateway(%{
      "methods" => ["http_request"],
      "response_chunks" => %{"max_total_bytes" => 4_194_304, "chunk_bytes" => 32_768}
    })

    {:ok, agent: agent, ctx: %{agent_id: agent, group_id: group}}
  end

  defp gateway(lan_gateway) do
    capabilities = %{"lan_gateway" => lan_gateway}

    Process.put(
      :lan_device,
      {:ok,
       %{
         "device_id" => "dev-gw",
         "environment_id" => "env-gw",
         "status" => "connected",
         "capabilities" => capabilities,
         "environments" => [
           %{
             "environment_id" => "env-gw",
             "environment_provider" => "connector",
             "status" => "connected",
             "capabilities" => capabilities
           }
         ]
       }}
    )
  end

  defp snapshot(ctx) do
    LanGateway.lan_request(
      %{
        "device_id" => "dev-gw",
        "url" => @snapshot,
        "response" => "binary",
        "auth" => %{
          "type" => "http_digest",
          "username" => "admin",
          "secret_ref" => "office-camera"
        }
      },
      ctx
    )
  end

  # RFC 2617, section 3.5.
  test "the Digest answer matches the RFC example" do
    challenge =
      HttpDigestAuth.challenge(
        ~s(Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41")
      )

    assert {:ok, header} =
             HttpDigestAuth.authorization(
               challenge,
               "GET",
               "/dir/index.html",
               "Mufasa",
               "Circle Of Life",
               cnonce: "0a4f113b"
             )

    assert header =~ ~s(response="6629fae49393a05397450978507c4ef1")
    assert header =~ ~s(opaque="5ccc069c403ebaf9f0171e9517f40e41")
    assert header =~ ~s(qop=auth, nc=00000001, cnonce="0a4f113b")
  end

  test "a snapshot behind Digest becomes a workspace image the model sees", %{
    agent: agent,
    ctx: ctx
  } do
    assert {content, [event]} = snapshot(ctx)

    assert_received {:request, "http_request", first}
    assert first["response_mode"] == "chunks"
    assert first["max_bytes"] == 4_194_304
    refute Map.has_key?(first["headers"] || %{}, "Authorization")

    assert_received {:request, "http_request",
                     %{"headers" => %{"Authorization" => authorization}}}

    assert authorization =~ ~s(uri="/stream/snapshot.jpg?channel=1")
    refute authorization =~ @password
    refute content =~ @password

    assert [%{"type" => "text", "text" => summary}, %{"type" => "image"} = image] =
             Jason.decode!(content)

    assert %{"status" => 200, "content_type" => "image/png", "size_bytes" => 8, "path" => path} =
             Jason.decode!(summary)

    assert image["file_ref"] == %{"environment_id" => "vfs", "path" => path}
    refute content =~ Base.encode64(@png)

    {:ok, _} = AgentWorkspace.seed_operation(agent, "snapshot", %{}, [event])
    assert {:ok, @png} = AgentWorkspace.read(agent, path)

    # The next model request carries the picture.
    session =
      SalixVerifiedKernel.Session.new(agent, "snapshot")
      |> SalixVerifiedKernel.Session.export()
      |> Map.put(:messages, [
        %{id: 1, role: "user", content: "看看办公室现在有没有人"},
        %{
          id: 2,
          role: "assistant",
          content: "",
          tool_calls: [%{"id" => "shot", "name" => "device.lan_request", "args" => %{}}]
        },
        %{
          id: 3,
          role: "tool",
          tool_name: "device.lan_request",
          tool_call_id: "shot",
          content: content
        }
      ])
      |> SalixVerifiedKernel.Session.open()

    {protocol, cfg} =
      SalixLlm.Provider.request_config(%{"protocol" => "chat", "model" => "image-model"})

    assert {:ok, body, _} =
             SalixVerifiedKernel.Session.query(
               session,
               :round_request,
               %{
                 "role" => "worker",
                 "canonical_router" => false,
                 "protocol" => protocol,
                 "cfg" => cfg,
                 "tools" => [],
                 "mode" => "complete"
               },
               ImageRefs.reader(%{agent_id: agent, model_supports_images: true})
             )

    assert body =~ Base.encode64(@png)
  end
end
