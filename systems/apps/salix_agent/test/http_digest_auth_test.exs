defmodule SalixAgent.HttpDigestAuthTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.HttpDigestAuth

  @challenge %{
    "realm" => "testrealm@host.com",
    "nonce" => "dcd98b7102dd2f0e8b11d0f600bfb0c093"
  }
  @cnonce "0a4f113b"

  # RFC 2617's credentials and URI. Expected responses were computed
  # independently with Python hashlib, including the session HA1 transform.
  @vectors [
    {"MD5", "670fd8c2df070c60b045671b8b24ff02", "6629fae49393a05397450978507c4ef1"},
    {"MD5-sess", "4726bc10c33fa6cb357eb27807b1cce8", "8e3825c57e897f5a0dec6c2d4e5059d0"},
    {"SHA-256", "e71f89d8267982ee1cd4dfb3637698eaf2f55848fe056aee7be175262aab5d2a",
     "5abdd07184ba512a22c53f41470e5eea7dcaa3a93a59b630c13dfe0a5dc6e38b"},
    {"SHA-256-sess", "6f421709505a71923c950606510a113314a303e5224f5d6390e4ad42cb718479",
     "b8822e12417cb7750f4e2b8515f0dcf25b7dd26993e80bee1426201446a7f59b"}
  ]

  for {algorithm, no_qop, auth} <- @vectors do
    test "#{algorithm} without qop sends exactly the inputs needed to verify its response" do
      header = authorize(Map.put(@challenge, "algorithm", unquote(algorithm)))
      assert header =~ ~s(response="#{unquote(no_qop)}")
      assert header =~ "algorithm=#{unquote(algorithm)}"
      assert header =~ ~s(uri="/dir/index.html")
      refute header =~ "qop="
      refute header =~ "nc="

      if String.ends_with?(unquote(algorithm), "-sess") do
        assert header =~ ~s(cnonce="#{@cnonce}")
      else
        refute header =~ "cnonce="
      end
    end

    test "#{algorithm} with qop auth preserves the response and nonce fields" do
      header =
        authorize(Map.merge(@challenge, %{"algorithm" => unquote(algorithm), "qop" => "auth"}))

      assert header =~ ~s(response="#{unquote(auth)}")
      assert header =~ ~s(qop=auth, nc=00000001, cnonce="#{@cnonce}")
      assert length(Regex.scan(~r/\bcnonce=/, header)) == 1
    end
  end

  defp authorize(challenge) do
    assert {:ok, header} =
             HttpDigestAuth.authorization(
               challenge,
               "GET",
               "/dir/index.html",
               "Mufasa",
               "Circle Of Life",
               cnonce: @cnonce
             )

    header
  end
end
