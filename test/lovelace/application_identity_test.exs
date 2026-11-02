defmodule Lovelace.ApplicationIdentityTest do
  use ExUnit.Case, async: false

  test "the OTP application owns the renamed application and web modules" do
    assert Application.spec(:lovelace, :mod) == {Lovelace.Application, []}
    assert Application.get_application(Lovelace.Repo) == :lovelace
    assert Application.get_application(LovelaceWeb.Endpoint) == :lovelace
    assert Application.fetch_env!(:lovelace, :ecto_repos) == [Lovelace.Repo]
    assert is_pid(Process.whereis(Lovelace.Supervisor))
    assert is_pid(Process.whereis(Lovelace.PubSub))
  end

  test "database metrics follow the renamed repo telemetry prefix" do
    prefix = Lovelace.Repo.config()[:telemetry_prefix]
    assert prefix == [:lovelace, :repo]

    query_metrics =
      Enum.filter(LovelaceWeb.Telemetry.metrics(), fn metric ->
        Enum.take(metric.name, 2) == prefix
      end)

    assert length(query_metrics) == 5
    assert Enum.all?(query_metrics, &(&1.event_name == prefix ++ [:query]))
  end
end
