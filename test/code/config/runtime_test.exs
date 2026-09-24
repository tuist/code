defmodule Code.Config.RuntimeTest do
  @moduledoc """
  Boot-time validation. Each of these used to be accepted and fail later, or
  not fail at all: an open admin API, an allow-everything backend in
  production, a listener that gave up on in-flight clones after 15 seconds.
  """

  use ExUnit.Case, async: true

  alias Code.Config
  alias Code.Config.Runtime

  describe "auth_backend!/2" do
    test "refuses the allow-everything backend in production" do
      error = assert_raise ArgumentError, fn -> Runtime.auth_backend!("none", :prod) end
      assert Exception.message(error) =~ "CODE_AUTH_BACKEND=none is refused in production"
    end

    test "keeps the allow-everything backend for development and tests" do
      assert Runtime.auth_backend!("none", :dev) == :none
      assert Runtime.auth_backend!("none", :test) == :none
    end

    test "accepts the real backends in production" do
      for {name, backend} <- [{"oidc", :oidc}, {"webhook", :webhook}, {"static", :static}] do
        assert Runtime.auth_backend!(name, :prod) == backend
      end
    end

    test "names the valid choices for an unknown backend" do
      error = assert_raise ArgumentError, fn -> Runtime.auth_backend!("ldap", :prod) end
      assert Exception.message(error) =~ "oidc, webhook, static, none"
    end
  end

  describe "secret!/2" do
    test "refuses a missing, empty or whitespace secret" do
      for value <- [nil, "", "   ", " ", "\t\n"] do
        error = assert_raise ArgumentError, fn -> Runtime.secret!("CODE_ADMIN_TOKEN", value) end
        assert Exception.message(error) =~ "CODE_ADMIN_TOKEN must be set to a non-empty value"
      end
    end

    test "returns a real secret unchanged" do
      assert Runtime.secret!("CODE_ADMIN_TOKEN", "s3cret") == "s3cret"
    end
  end

  describe "ip!/2" do
    test "unset means all interfaces" do
      assert Runtime.ip!("CODE_ADMIN_IP", nil) == nil
      assert Runtime.ip!("CODE_ADMIN_IP", "") == nil
    end

    test "parses IPv4 and IPv6 addresses" do
      assert Runtime.ip!("CODE_ADMIN_IP", "127.0.0.1") == {127, 0, 0, 1}
      assert Runtime.ip!("CODE_ADMIN_IP", "::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "refuses something that is not an address" do
      assert_raise ArgumentError, ~r/CODE_ADMIN_IP must be/, fn ->
        Runtime.ip!("CODE_ADMIN_IP", "localhost")
      end
    end
  end

  describe "non_neg_integer!/2" do
    test "parses durations and refuses anything else" do
      assert Runtime.non_neg_integer!("CODE_SHUTDOWN_TIMEOUT_MS", "100000") == 100_000
      assert Runtime.non_neg_integer!("CODE_SHUTDOWN_TIMEOUT_MS", "0") == 0

      for value <- ["-1", "10s", ""] do
        assert_raise ArgumentError, fn -> Runtime.non_neg_integer!("CODE_SHUTDOWN_TIMEOUT_MS", value) end
      end
    end
  end

  describe "listeners" do
    test "drain for the configured shutdown timeout" do
      # Thousand Island defaults to 15 seconds, far below the chart's grace
      # period, so every listener must carry the configured value.
      Config.put_overrides(%{shutdown_timeout_ms: 42_000})

      for opts <- [
            [plug: Code.HTTP.AdminRouter, port: 0],
            [plug: Code.HTTP.Router, port: 0, thousand_island_options: [num_acceptors: 3]]
          ] do
        %{start: {Bandit, :start_link, [bandit]}} = Code.Application.listener(Code.HTTP.Admin, opts)
        assert bandit[:thousand_island_options][:shutdown_timeout] == 42_000
      end

      # Options the caller set survive the merge.
      %{start: {Bandit, :start_link, [bandit]}} =
        Code.Application.listener(Code.HTTP.Public,
          plug: Code.HTTP.Router,
          port: 0,
          thousand_island_options: [num_acceptors: 3]
        )

      assert bandit[:thousand_island_options][:num_acceptors] == 3
    end

    test "the default shutdown timeout fits the chart's grace period" do
      Config.put_overrides(%{})
      # 120 s grace, 10 s preStop, 5 s margin.
      assert Config.shutdown_timeout_ms() <= :timer.seconds(105)
      assert Config.shutdown_timeout_ms() > :timer.seconds(15)
    end
  end
end
