defmodule ClusterMurmur.Triggers.EventTriggerCooldownTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate

  alias ClusterMurmur.Triggers.{
    EventTrigger,
    EventTriggerCooldown
  }

  @now ~U[2026-08-04 12:00:00.123456Z]

  test "plans the next cooldown deadline from an injected eligible instant" do
    assert EventTriggerCooldown.evaluate(trigger(60_000), nil, @now) ==
             {:ok, {:eligible, ~U[2026-08-04 12:01:00.123456Z]}}

    assert EventTriggerCooldown.evaluate(trigger(0), nil, @now) ==
             {:ok, {:eligible, @now}}
  end

  test "skips only while the persisted cooldown is strictly active" do
    assert EventTriggerCooldown.evaluate(
             trigger(60_000),
             ~U[2026-08-04 12:00:00.123457Z],
             @now
           ) == {:ok, {:skip, :cooldown}}

    for expired <- [@now, ~U[2026-08-04 11:59:59.999999Z]] do
      assert EventTriggerCooldown.evaluate(trigger(60_000), expired, @now) ==
               {:ok, {:eligible, ~U[2026-08-04 12:01:00.123456Z]}}
    end
  end

  test "rejects invalid triggers before returning a decision" do
    valid = trigger(60_000)

    for invalid <- [
          nil,
          %{valid | id: "invalid id"},
          %{valid | matcher: %Matcher{predicates: []}}
        ] do
      assert {:error, reason} = EventTriggerCooldown.evaluate(invalid, nil, @now)
      assert reason in [:invalid_trigger, :invalid_trigger_matcher]
    end
  end

  test "rejects forged and non-UTC instants" do
    {:ok, local} =
      DateTime.shift_zone(@now, "Asia/Tokyo", TimeZoneInfo.TimeZoneDatabase)

    forged = Map.put(@now, :unexpected_private_value, "private")

    for {cooldown_until, now} <- [
          {nil, nil},
          {local, @now},
          {forged, @now},
          {nil, %{@now | hour: 24}}
        ] do
      result = EventTriggerCooldown.evaluate(trigger(60_000), cooldown_until, now)
      assert result == {:error, :invalid_datetime}
      refute inspect(result) =~ "private"
    end
  end

  test "fails closed when the next deadline leaves the storage year range" do
    near_limit = ~U[9999-12-31 23:59:59.999999Z]

    assert EventTriggerCooldown.evaluate(trigger(1), nil, near_limit) ==
             {:error, :invalid_datetime}
  end

  defp trigger(cooldown_ms) do
    %EventTrigger{
      id: "example-trigger",
      matcher: %Matcher{predicates: [%Predicate{field: "type", operator: :exists}]},
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: cooldown_ms
    }
  end
end
