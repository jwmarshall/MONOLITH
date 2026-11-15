defmodule Monolith.CachingTest do
  use Monolith.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Monolith.Caching
  alias Monolith.Caching.Preference

  @owner %{role: :local_owner}

  test "preferences persist independently and only the owner can change them" do
    for actor <- [nil, %{}, %{role: "local_owner"}, %{role: :cache_policy}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Caching.save_preferences(:gmail, 10, 1, actor: actor)
    end

    for actor <- [nil, %{}, %{role: "local_owner"}] do
      assert {:error, %Ash.Error.Forbidden{}} = Caching.preferences(actor: actor)
    end

    assert Caching.policy!(:gmail).refresh_seconds == 180
    assert Caching.policy!(:calendar).retention_seconds == 86_400
    assert Caching.policy!(:github).refresh_seconds == 300
    assert {:ok, []} = Caching.preferences(actor: @owner)

    assert {:ok, %{refresh_minutes: 10, retention_hours: 1}} =
             Caching.save_preferences(:gmail, 10, 1, actor: @owner)

    assert Caching.policy!(:gmail).refresh_seconds == 600
    assert Caching.policy!(:gmail).retention_seconds == 3600
    assert Caching.policy!(:calendar).refresh_seconds == 180
    assert Caching.policy!(:github).retention_seconds == 86_400
    assert [%Preference{integration: :gmail}] = Caching.preferences!(actor: @owner)
  end

  test "bounds are integration-specific and invalid saves leave the policy unchanged" do
    for {integration, refresh, retention} <- [
          {:gmail, 2, 24},
          {:gmail, 61, 24},
          {:gmail, 3, 0},
          {:gmail, 3, 169},
          {:calendar, 2, 24},
          {:calendar, 3, 25},
          {:github, 4, 24},
          {:github, 5, 25},
          {:gmail, "3.5", 24},
          {:gmail, nil, 24},
          {:gmail, 3, nil},
          {:other, 3, 24}
        ] do
      assert {:error, _} =
               Caching.save_preferences(integration, refresh, retention, actor: @owner)
    end

    assert {:ok, []} = Caching.preferences(actor: @owner)

    for {integration, refresh, retention} <- [
          {:gmail, 60, 168},
          {:calendar, 60, 24},
          {:github, 60, 24}
        ] do
      assert {:ok, _} = Caching.save_preferences(integration, refresh, retention, actor: @owner)
      assert Caching.policy!(integration).refresh_seconds == 3600
    end
  end

  test "shortening and lengthening cannot resurrect an expired observation" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -7200)
    recent = DateTime.add(now, -600)
    assert Caching.retained?(Caching.policy!(:gmail), old)
    Caching.save_preferences!(:gmail, 10, 1, actor: @owner)
    refute Caching.retained?(Caching.policy!(:gmail), old)
    assert Caching.retained?(Caching.policy!(:gmail), recent)
    Caching.save_preferences!(:gmail, 20, 168, actor: @owner)
    refute Caching.retained?(Caching.policy!(:gmail), old)
    assert Caching.retained?(Caching.policy!(:gmail), recent)

    # Simulate time accrued under the preceding one-hour policy without cleanup:
    # the two-hour-old observation is newer than its three-hour-old watermark.
    Caching.save_preferences!(:calendar, 3, 1, actor: @owner)
    watermark = now |> DateTime.add(-10_800) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

    SQL.query!(
      Monolith.Repo,
      "UPDATE cache_preferences SET expired_before = ? WHERE integration = ?",
      [watermark, "calendar"]
    )

    previous = Caching.policy!(:calendar)
    assert DateTime.compare(old, previous.expired_before) == :gt
    refute Caching.retained?(previous, old)
    Caching.save_preferences!(:calendar, 3, 24, actor: @owner)
    refute Caching.retained?(Caching.policy!(:calendar), old)
  end

  test "freshness boundaries reject unknown and future observations and respect retention" do
    now = ~U[2026-11-14 12:00:00.000000Z]
    policy = Caching.policy(:gmail, nil)
    assert Caching.fresh?(policy, DateTime.add(now, -179), now)
    refute Caching.fresh?(policy, DateTime.add(now, -180), now)
    assert Caching.retained?(policy, DateTime.add(now, -180), now)
    refute Caching.retained?(policy, DateTime.add(now, -604_800), now)
    refute Caching.fresh?(policy, nil, now)
    refute Caching.fresh?(policy, DateTime.add(now, 1), now)
  end
end
