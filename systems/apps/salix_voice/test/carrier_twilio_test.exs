defmodule SalixVoice.Carrier.TwilioTest do
  use ExUnit.Case, async: true

  alias SalixVoice.Carrier.Twilio

  @stream_sid "MZ0000000000000000000000000000abcd"

  defp start(state) do
    frame =
      Jason.encode!(%{
        "event" => "start",
        "sequenceNumber" => "1",
        "start" => %{
          "accountSid" => "AC00000000000000000000000000000001",
          "streamSid" => @stream_sid,
          "callSid" => "CA00000000000000000000000000000001",
          "tracks" => ["inbound"],
          "mediaFormat" => %{"encoding" => "audio/x-mulaw", "sampleRate" => 8000, "channels" => 1},
          "customParameters" => %{"call" => "vc_1"}
        },
        "streamSid" => @stream_sid
      })

    Twilio.decode({:text, frame}, state)
  end

  describe "Media Streams" do
    test "decodes the inbound message sequence into call events" do
      state = Twilio.new()

      assert {:ok, [:connected], state} =
               Twilio.decode(
                 {:text, ~s({"event":"connected","protocol":"Call","version":"1.0.0"})},
                 state
               )

      assert {:ok, [{:start, info}], state} = start(state)
      assert info.call_sid == "CA00000000000000000000000000000001"
      assert info.custom_parameters == %{"call" => "vc_1"}

      audio = <<0xFF, 0x7F, 0x00, 0x80>>

      media =
        Jason.encode!(%{
          "event" => "media",
          "sequenceNumber" => "2",
          "media" => %{
            "track" => "inbound",
            "chunk" => "1",
            "timestamp" => "5",
            "payload" => Base.encode64(audio)
          },
          "streamSid" => @stream_sid
        })

      assert {:ok, [{:audio, ^audio}], state} = Twilio.decode({:text, media}, state)

      outbound = String.replace(media, ~s("inbound"), ~s("outbound"))
      assert {:ok, [], state} = Twilio.decode({:text, outbound}, state)

      mark =
        ~s({"event":"mark","sequenceNumber":"4","streamSid":"#{@stream_sid}","mark":{"name":"m1"}})

      assert {:ok, [{:mark_played, "m1"}], state} = Twilio.decode({:text, mark}, state)

      dtmf =
        ~s({"event":"dtmf","streamSid":"#{@stream_sid}","sequenceNumber":"5","dtmf":{"track":"inbound_track","digit":"1"}})

      assert {:ok, [{:dtmf, "1"}], state} = Twilio.decode({:text, dtmf}, state)

      stop =
        ~s({"event":"stop","sequenceNumber":"5","stop":{"accountSid":"AC1","callSid":"CA1"},"streamSid":"#{@stream_sid}"})

      assert {:ok, [{:hangup, :caller_hangup}], _state} = Twilio.decode({:text, stop}, state)
    end

    test "rejects malformed frames and ignores unknown events" do
      state = Twilio.new()
      assert {:error, :bad_frame} = Twilio.decode({:text, "not json"}, state)
      assert {:error, :bad_frame} = Twilio.decode({:binary, <<1, 2>>}, state)

      assert {:error, :bad_frame} =
               Twilio.decode({:text, ~s({"event":"media","media":{"payload":"%%%"}})}, state)

      assert {:ok, [], ^state} = Twilio.decode({:text, ~s({"event":"future"})}, state)
    end

    test "encodes media, mark and clear for the stream, and nothing before start" do
      assert {[], _} = Twilio.encode({:audio, <<1>>}, Twilio.new())
      {:ok, _events, state} = start(Twilio.new())

      assert {[{:text, media}], ^state} = Twilio.encode({:audio, <<1, 2, 3>>}, state)

      assert Jason.decode!(media) == %{
               "event" => "media",
               "streamSid" => @stream_sid,
               "media" => %{"payload" => Base.encode64(<<1, 2, 3>>)}
             }

      assert {[{:text, mark}], _} = Twilio.encode({:mark, "m2"}, state)

      assert Jason.decode!(mark) == %{
               "event" => "mark",
               "streamSid" => @stream_sid,
               "mark" => %{"name" => "m2"}
             }

      assert {[{:text, clear}], _} = Twilio.encode(:clear, state)
      assert Jason.decode!(clear) == %{"event" => "clear", "streamSid" => @stream_sid}

      assert {[], _} = Twilio.encode({:transcript, :caller, "hi", true}, state)
      assert {[], _} = Twilio.encode({:end, :completed}, state)
    end
  end

  describe "TwiML" do
    test "Connect Stream escapes the URL and carries parameters" do
      twiml =
        Twilio.connect_stream_twiml("wss://voice.example/v1/voice/twilio/stream/a.b?x=1&y=2", %{
          "call_id" => "vc_1"
        })

      assert twiml ==
               ~s(<?xml version="1.0" encoding="UTF-8"?><Response><Connect>) <>
                 ~s(<Stream url="wss://voice.example/v1/voice/twilio/stream/a.b?x=1&amp;y=2">) <>
                 ~s(<Parameter name="call_id" value="vc_1"/></Stream></Connect></Response>)
    end

    test "Say plus Hangup and the PIN Gather escape spoken text" do
      assert Twilio.say_hangup_twiml("Sorry <you> & me") ==
               ~s(<?xml version="1.0" encoding="UTF-8"?><Response>) <>
                 "<Say>Sorry &lt;you&gt; &amp; me</Say><Hangup/></Response>"

      gather = Twilio.gather_pin_twiml("https://voice.example/pin?c=1&d=2", "Enter your PIN.")
      assert gather =~ ~s(<Gather input="dtmf" numDigits="6")
      assert gather =~ ~s(action="https://voice.example/pin?c=1&amp;d=2" method="POST")
      assert gather =~ "<Say>Enter your PIN.</Say></Gather>"
      assert String.ends_with?(gather, "<Hangup/></Response>")
    end
  end

  describe "X-Twilio-Signature" do
    # The worked example from Twilio's webhook security documentation.
    @url "https://example.com/myapp.php?foo=1&bar=2"
    @params %{
      "CallSid" => "CA1234567890ABCDE",
      "Caller" => "+14158675310",
      "Digits" => "1234",
      "From" => "+14158675310",
      "To" => "+18005551212"
    }

    test "matches Twilio's documented example" do
      assert Twilio.signature(@url, @params, "12345") == "L/OH5YylLD5NRKLltdqwSvS0BnU="
      assert Twilio.valid_signature?(@url, @params, "L/OH5YylLD5NRKLltdqwSvS0BnU=", "12345")
    end

    test "fails closed on a changed parameter, URL, token or missing header" do
      signature = "L/OH5YylLD5NRKLltdqwSvS0BnU="

      refute Twilio.valid_signature?(
               @url,
               Map.put(@params, "From", "+15550000000"),
               signature,
               "12345"
             )

      refute Twilio.valid_signature?(@url <> "&z=3", @params, signature, "12345")
      refute Twilio.valid_signature?(@url, @params, signature, "54321")
      refute Twilio.valid_signature?(@url, @params, nil, "12345")
      refute Twilio.valid_signature?(@url, @params, signature, nil)
    end

    test "accepts a signature computed with the default port present or absent" do
      signed_with_port =
        Twilio.signature("https://example.com:443/myapp.php?foo=1&bar=2", @params, "12345")

      assert Twilio.valid_signature?(@url, @params, signed_with_port, "12345")
    end
  end
end
