defmodule SalixAgent.DecideFixture do
  @moduledoc false
  import ExUnit.Callbacks
  @behaviour Plug

  def start_provider do
    server =
      start_supervised!(
        {Bandit, plug: {__MODULE__, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}/v1/systemone"

    json =
      Jason.decode!(
        Jason.encode!(%{
          "decide" => %{
            "endpoint" => endpoint,
            "api_key" => "test-decide-secret",
            "model" => "jev-fixture"
          }
        })
      )

    for {:salix_agent, :decide, config} <- SalixStore.ConfigJson.app_env(json) do
      put_env(:decide, config)
    end

    endpoint
  end

  def put_env(key, value) do
    old = Application.get_env(:salix_agent, key)
    Application.put_env(:salix_agent, key, value)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:salix_agent, key),
        else: Application.put_env(:salix_agent, key, old)
    end)
  end

  def args(state \\ "meeting decisions") do
    %{
      "state" => state,
      "questions" => %{
        "source" => %{
          "type" => "choice",
          "instructions" => "Choose the source or none",
          "criteria" => %{"meetings" => "Meeting decisions", "none" => "No match"}
        },
        "relevant" => %{"type" => "noul", "instructions" => "Is this relevant?"},
        "priority" => %{
          "type" => "score",
          "instructions" => "Rate urgency",
          "criteria" => ["Routine", "Urgent"]
        }
      }
    }
  end

  @impl true
  def init(pid), do: pid
  @impl true
  def call(conn, pid) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(raw)

    send(
      pid,
      {:decision_request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
       body}
    )

    state =
      case body["state"] do
        %{"message" => %{"text" => text}} -> text
        value -> value
      end

    if state == "slow", do: Process.sleep(3_000)

    cond do
      state == "redirect" ->
        conn
        |> Plug.Conn.put_resp_header("location", "/unexpected")
        |> Plug.Conn.send_resp(302, "")

      state == "rate" ->
        Plug.Conn.send_resp(conn, 429, "test-decide-secret")

      state == "large" ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("x", 70_000))

      true ->
        answers =
          Map.new(body["questions"], fn {key, q} ->
            a =
              case q["type"] do
                "choice" ->
                  choice = if state == "unknown", do: "unauthorized", else: "meetings"
                  confidence = if state == "uncertain", do: 0.01, else: 0.81239

                  %{
                    "type" => "choice",
                    "choice" => choice,
                    "confidence" => confidence,
                    "probabilities" => %{"meetings" => 0.9, "none" => 0.1}
                  }

                "noul" ->
                  relevant =
                    case Application.get_env(:salix_agent, :decide_selected_miniskill) do
                      nil ->
                        state != "no-match"

                      selected ->
                        Enum.any?(body["state"]["miniskills"], fn skill ->
                          skill["id"] == key and skill["name"] == selected
                        end)
                    end

                  %{"type" => "noul", "noul" => if(relevant, do: 0.92349, else: 0.1)}

                "score" ->
                  %{
                    "type" => "score",
                    "score" => 0.8,
                    "confidence" => 0.7,
                    "probabilities" => %{"0" => 0.2, "1" => 0.8}
                  }
              end

            {key, a}
          end)

        answers = if state == "missing", do: %{}, else: answers

        response = %{
          "model" => "jev-fixture-resolved",
          "answers" => answers,
          "usage" => %{"input_tokens" => 123, "output_tokens" => 7}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  defmodule Meter do
    def before_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :decide_test_pid), {:decision_meter_before, fact})
      if Application.get_env(:salix_agent, :decide_test_deny), do: {:error, :denied}, else: :ok
    end

    def after_llm_call(fact) do
      send(Application.fetch_env!(:salix_agent, :decide_test_pid), {:decision_meter_after, fact})
      :ok
    end
  end

  defmodule Archive do
    def record(fact) do
      send(Application.fetch_env!(:salix_agent, :decide_test_pid), {:decision_archive, fact})
      :ok
    end
  end
end
