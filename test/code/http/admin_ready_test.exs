defmodule Code.HTTP.AdminReadyTest do
  @moduledoc """
  Readiness is probed on every pod every few seconds, so its cost must not
  depend on how much the bucket holds.
  """

  use Code.Case, async: true
  use Mimic

  import Plug.Test

  alias Code.HTTP.AdminRouter
  alias Code.ObjectStore

  setup :set_mimic_private
  setup :verify_on_exit!

  defp ready, do: AdminRouter.call(conn(:get, "/ready"), AdminRouter.init([]))

  test "is ready when the store answers a bounded probe, without listing it", %{repo: repo} do
    {:ok, _} = Code.WAL.create(repo)
    stub(ObjectStore, :list, fn prefix -> flunk("readiness listed #{prefix}") end)

    conn = ready()

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"status" => "ready"}
  end

  test "is not ready when the store cannot be reached" do
    stub(ObjectStore, :probe, fn -> {:error, :econnrefused} end)

    conn = ready()

    assert conn.status == 503
    assert %{"status" => "not_ready"} = JSON.decode!(conn.resp_body)
  end
end
