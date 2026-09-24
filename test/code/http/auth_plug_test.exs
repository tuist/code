defmodule Code.HTTP.AuthPlugTest do
  @moduledoc """
  Authentication failures used to be silent. They are now counted by a
  bounded reason, so a misconfigured issuer or an unreachable authority shows
  up on a dashboard before it shows up in a support ticket.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.HTTP.AuthPlug

  setup do
    Code.Config.put_overrides(%{
      auth: {Code.Auth.Static, tokens: %{"good-token" => %{account: "acme", scopes: [:read]}}}
    })

    test = self()
    handler = "auth-rejected-#{:erlang.unique_integer([:positive])}"

    # Handlers run in the emitting process, which for a plug is this test.
    :telemetry.attach(
      handler,
      [:code, :auth, :rejected],
      fn _event, _measurements, metadata, _config ->
        if self() == test, do: send(test, {:rejected, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp call(authorization) do
    conn = conn(:get, "/")
    conn = if authorization, do: put_req_header(conn, "authorization", authorization), else: conn
    AuthPlug.call(conn, AuthPlug.init([]))
  end

  test "a rejected credential is reported with a bounded reason" do
    conn = call("Bearer wrong-token")

    assert conn.assigns.auth_error == :invalid_credential
    assert_received {:rejected, %{reason: "invalid_credential"}}
  end

  test "an anonymous request is not a failure" do
    # `git` always tries without credentials first.
    conn = call(nil)

    assert conn.assigns.auth_error == :unauthenticated
    refute_received {:rejected, _}
  end

  test "an accepted credential is not reported" do
    conn = call("Bearer good-token")

    assert conn.assigns.principal.account == "acme"
    refute_received {:rejected, _}
  end

  test "labels never carry the values some reasons wrap" do
    # These wrap attacker-controlled claims, key ids and statuses; any of them
    # as a metric label would be unbounded cardinality.
    for {reason, label} <- [
          {{:issuer_mismatch, "https://attacker.example"}, "issuer_mismatch"},
          {{:audience_mismatch, ["someone-else"]}, "audience_mismatch"},
          {{:unknown_key, "kid-#{:erlang.unique_integer()}"}, "unknown_key"},
          {{:authority_status, 502}, "authority_unavailable"},
          {{:jwks_status, 503}, "key_source_unavailable"},
          {%Req.TransportError{reason: :timeout}, "key_source_unavailable"},
          {{:something, "new"}, "other"}
        ] do
      assert {_class, ^label} = AuthPlug.classify(reason)
    end
  end

  test "operator-side failures are distinguished from caller mistakes" do
    assert {:client, _} = AuthPlug.classify(:expired)
    assert {:client, _} = AuthPlug.classify(:invalid_signature)
    assert {:server, _} = AuthPlug.classify(:no_audience_configured)
    assert {:server, _} = AuthPlug.classify(:authority_unreachable)
    assert {:server, _} = AuthPlug.classify(:jwks_timeout)
  end
end
