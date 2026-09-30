defmodule CommaWeb.ClientSurfaceTest do
  use ExUnit.Case, async: false

  @canonical_origin "https://app.comma.surf"
  @admin_origin "https://admin.comma.surf"
  @secondary_origin "https://preview.comma.surf"

  setup do
    previous_allowed_origins = Application.get_env(:comma_web, :allowed_origins)
    previous_web_cookie_origin = Application.get_env(:comma_web, :web_cookie_origin)
    previous_admin_cookie_origin = Application.get_env(:comma_web, :admin_cookie_origin)

    on_exit(fn ->
      restore_env(:allowed_origins, previous_allowed_origins)
      restore_env(:web_cookie_origin, previous_web_cookie_origin)
      restore_env(:admin_cookie_origin, previous_admin_cookie_origin)
    end)

    :ok
  end

  test "startup accepts a broader CORS allowlist with distinct product and Admin Cookie origins" do
    Application.put_env(:comma_web, :allowed_origins, [
      @canonical_origin,
      @admin_origin,
      @secondary_origin
    ])

    Application.put_env(:comma_web, :web_cookie_origin, @canonical_origin)
    Application.put_env(:comma_web, :admin_cookie_origin, @admin_origin)

    assert :ok = CommaWeb.ClientSurface.validate_configuration!()
    assert CommaWeb.ClientSurface.allowed_web_origin?(@secondary_origin)
    refute CommaWeb.ClientSurface.web_cookie_origin?(@secondary_origin)
    assert CommaWeb.ClientSurface.web_cookie_origin?(@canonical_origin)
    assert CommaWeb.ClientSurface.admin_cookie_origin?(@admin_origin)
  end

  test "product and Admin Cookie origins have explicit non-overlapping protected paths" do
    put_valid_configuration()

    for path <- [
          "/v1/comma/auth/email/login",
          "/v1/comma/auth/email/verify",
          "/v1/comma/auth/google/attempt",
          "/v1/comma/auth/google",
          "/v1/comma/auth/google/link/verify"
        ] do
      assert CommaWeb.ClientSurface.public_auth_path?(path)
      assert CommaWeb.ClientSurface.web_cookie_path?(path)
      assert CommaWeb.ClientSurface.admin_cookie_path?(path)
    end

    refute CommaWeb.ClientSurface.public_auth_path?("/v1/comma/auth/session")
    refute CommaWeb.ClientSurface.public_auth_path?("/v1/comma/auth/logout")
    refute CommaWeb.ClientSurface.public_auth_path?("/v1/comma/billing/stripe/webhook")

    for path <- ["/v1/comma/auth/session", "/v1/comma/auth/logout"] do
      assert CommaWeb.ClientSurface.web_cookie_path?(path)
      assert CommaWeb.ClientSurface.admin_cookie_path?(path)
    end

    assert CommaWeb.ClientSurface.web_cookie_path?("/v1/comma/workspaces")
    refute CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/workspaces")
    refute CommaWeb.ClientSurface.web_cookie_path?("/v1/comma/admin/users")
    assert CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/users")
    assert CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/billing/redeem-codes")
    assert CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/model-selection-policy")
    assert CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/model-selection-policy/templates")
    refute CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/model-selection-policy-legacy")
    assert CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/audit-events")
    refute CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/audit-events/export")
    refute CommaWeb.ClientSurface.admin_cookie_path?("/v1/comma/admin/users-legacy")
    refute CommaWeb.ClientSurface.admin_cookie_path?("/v1/admin/vm/worker-release")

    assert CommaWeb.ClientSurface.origin_scope_violation?(
             @canonical_origin,
             "/v1/comma/admin/users"
           )

    assert CommaWeb.ClientSurface.origin_scope_violation?(
             @admin_origin,
             "/v1/comma/workspaces"
           )

    assert CommaWeb.ClientSurface.origin_scope_violation?(
             @admin_origin,
             "/v1/admin/vm/worker-release"
           )

    refute CommaWeb.ClientSurface.origin_scope_violation?(
             @canonical_origin,
             "/v1/comma/workspaces"
           )

    refute CommaWeb.ClientSurface.origin_scope_violation?(
             @admin_origin,
             "/v1/comma/admin/users"
           )

    refute CommaWeb.ClientSurface.origin_scope_violation?(
             @secondary_origin,
             "/v1/comma/admin/users"
           )
  end

  for {key, origin} <- [
        web_cookie_origin: @canonical_origin,
        admin_cookie_origin: @admin_origin
      ] do
    @key key
    @origin origin
    test "startup rejects missing, multiple, invalid, unlisted, or duplicated #{key}" do
      exactly_one = ~r/:#{@key} must be exactly one/
      appear_once = ~r/:#{@key} must appear exactly once/

      for {label, allowed_origins, value, expected} <- [
            {"missing", nil, :delete, exactly_one},
            {"multiple", nil, [@origin, @secondary_origin], exactly_one},
            {"with a path", nil, "#{@origin}/path", exactly_one},
            {"unlisted", nil, "https://unlisted.comma.surf", appear_once},
            {"listed twice", [@canonical_origin, @admin_origin, @origin], @origin, appear_once}
          ] do
        put_valid_configuration()

        if allowed_origins do
          Application.put_env(:comma_web, :allowed_origins, allowed_origins)
        end

        case value do
          :delete -> Application.delete_env(:comma_web, @key)
          value -> Application.put_env(:comma_web, @key, value)
        end

        error =
          assert_raise ArgumentError, fn ->
            CommaWeb.ClientSurface.validate_configuration!()
          end

        assert error.message =~ expected, "#{label}: #{error.message}"
      end
    end
  end

  test "startup rejects an Admin Cookie origin shared with the Web Cookie origin" do
    Application.put_env(:comma_web, :allowed_origins, [@canonical_origin])
    Application.put_env(:comma_web, :web_cookie_origin, @canonical_origin)
    Application.put_env(:comma_web, :admin_cookie_origin, @canonical_origin)

    assert_raise ArgumentError, ~r/admin_cookie_origin must differ/, fn ->
      CommaWeb.ClientSurface.validate_configuration!()
    end
  end

  defp put_valid_configuration do
    Application.put_env(:comma_web, :allowed_origins, [
      @canonical_origin,
      @admin_origin,
      @secondary_origin
    ])

    Application.put_env(:comma_web, :web_cookie_origin, @canonical_origin)
    Application.put_env(:comma_web, :admin_cookie_origin, @admin_origin)
  end

  defp restore_env(key, nil), do: Application.delete_env(:comma_web, key)
  defp restore_env(key, value), do: Application.put_env(:comma_web, key, value)
end
