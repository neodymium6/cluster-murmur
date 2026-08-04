defmodule ClusterMurmur.Config.TriggersTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{LoadedDocument, Triggers}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Triggers.{EmittedEvent, EventTrigger, ScheduleTrigger}

  test "validates, normalizes, and combines event-trigger documents" do
    first =
      loaded(%{
        "triggers" => [
          trigger("monitoring-failure", "monitoring-characters", "30m", [
            predicate("type", "equals", "observation.failed"),
            predicate("labels.category", "in", ["storage", "monitoring"])
          ])
        ]
      })

    second =
      loaded(%{
        "triggers" => [
          trigger("recovery", "recovery-characters", "0ms", [
            predicate("type", "equals", "observation.recovered")
          ])
        ]
      })

    assert {:ok, %Triggers{triggers: triggers} = normalized} =
             Triggers.parse_documents([second, first])

    assert Triggers.parse_documents([first, second]) == {:ok, normalized}
    assert Map.keys(triggers) |> Enum.sort() == ["monitoring-failure", "recovery"]

    assert %EventTrigger{
             id: "monitoring-failure",
             action: :start_conversation,
             binding: "monitoring-characters",
             cooldown_ms: 1_800_000,
             matcher: %{predicates: predicates}
           } = triggers["monitoring-failure"]

    assert Enum.any?(predicates, &match?(%Predicate{operator: :equals}, &1))

    assert %Predicate{operator: :in, values: ["monitoring", "storage"]} =
             Enum.find(predicates, &(&1.operator == :in))
  end

  test "accepts an empty category and empty trigger lists" do
    assert Triggers.parse_documents([]) == {:ok, %Triggers{triggers: %{}}}

    assert Triggers.parse_documents([loaded(%{"triggers" => []})]) ==
             {:ok, %Triggers{triggers: %{}}}
  end

  test "validates and normalizes schedule triggers alongside event triggers" do
    event = trigger("monitoring", "characters", "30m")
    schedule = schedule_trigger("daily-summary", "0 21 * * *", "Asia/Tokyo", "social")

    assert {:ok, %Triggers{triggers: triggers}} =
             Triggers.parse_documents([
               loaded(%{"triggers" => [schedule, event]})
             ])

    assert %EventTrigger{id: "monitoring"} = triggers["monitoring"]

    assert %ScheduleTrigger{
             id: "daily-summary",
             cron: %Crontab.CronExpression{
               extended: false,
               minute: [0],
               hour: [21]
             },
             timezone: "Asia/Tokyo",
             action: :emit_event,
             event: %EmittedEvent{
               type: "schedule.fired",
               group: "social",
               subject: "daily-summary"
             }
           } = triggers["daily-summary"]
  end

  test "accepts standard five-field cron syntax and embedded IANA links" do
    schedules = [
      schedule_trigger("ranges", "*/15 8-18 * JAN,MAR MON-FRI", "Etc/UTC", "social"),
      schedule_trigger("link", "0 0 1 * *", "Japan", "social")
    ]

    assert {:ok, %Triggers{triggers: triggers}} =
             Triggers.parse_documents([loaded(%{"triggers" => schedules})])

    assert map_size(triggers) == 2
  end

  test "rejects malformed schedules, nonstandard cron shapes, and unknown timezones" do
    valid = schedule_trigger("daily", "0 21 * * *", "Asia/Tokyo", "social")

    invalid = [
      put_in(valid, ["schedule", "cron"], "not a cron expression"),
      put_in(valid, ["schedule", "cron"], "*/1/2 * * * *"),
      put_in(valid, ["schedule", "cron"], "*/-1 * * * *"),
      put_in(valid, ["schedule", "cron"], "1-2/-3 * * * *"),
      put_in(valid, ["schedule", "cron"], "0 0 21 * * *"),
      put_in(valid, ["schedule", "cron"], "@daily"),
      put_in(valid, ["schedule", "cron"], "0  21 * * *"),
      put_in(valid, ["schedule", "cron"], "0 21 L * *"),
      put_in(valid, ["schedule", "cron"], "0 21 1W * *"),
      put_in(valid, ["schedule", "cron"], "0 21 * * MON#2"),
      put_in(valid, ["schedule", "cron"], "0 21 * * 5L"),
      put_in(valid, ["schedule", "cron"], "0 0 1 * MON"),
      put_in(valid, ["schedule", "cron"], "0 0 */2 * MON"),
      put_in(valid, ["schedule", "timezone"], "example.invalid"),
      put_in(valid, ["action", "type"], "start_conversation"),
      put_in(valid, ["action", "event", "group"], "invalid group"),
      put_in(valid, ["schedule", "extra"], true),
      put_in(valid, ["action", "event", "extra"], true),
      Map.put(valid, "cooldown", "1h")
    ]

    for attributes <- invalid do
      assert Triggers.parse_documents([loaded(%{"triggers" => [attributes]})]) ==
               {:error, :invalid_trigger_document}
    end
  end

  test "rejects malformed and unsupported trigger shapes" do
    valid = trigger("monitoring", "characters", "30m", [predicate("type", "exists")])

    invalid_documents = [
      %{},
      %{"triggers" => %{}},
      %{"triggers" => [Map.put(valid, "extra", true)]},
      %{"triggers" => [Map.delete(valid, "event")]},
      %{"triggers" => [put_in(valid, ["event", "extra"], true)]},
      %{"triggers" => [put_in(valid, ["action", "extra"], true)]},
      %{"triggers" => [put_in(valid, ["action", "type"], "emit_event")]},
      %{"triggers" => [%{"id" => "daily", "schedule" => %{}, "action" => %{}}]},
      %{"triggers" => [%{"id" => "ambient", "stochastic" => %{}, "action" => %{}}]}
    ]

    for document <- invalid_documents do
      assert Triggers.parse_documents([loaded(document)]) == {:error, :invalid_trigger_document}
    end
  end

  test "validates IDs, cooldowns, and event matchers semantically" do
    invalid = [
      trigger("invalid id", "characters", "30m", [predicate("type", "exists")]),
      trigger("monitoring", "invalid binding", "30m", [predicate("type", "exists")]),
      trigger("monitoring", "characters", "later", [predicate("type", "exists")]),
      trigger("monitoring", "characters", "30m", [predicate("payload.value", "exists")]),
      trigger("monitoring", "characters", "30m", [
        %{"field" => "type", "operator" => "matches", "value" => ".*"}
      ])
    ]

    for attributes <- invalid do
      assert Triggers.parse_documents([loaded(%{"triggers" => [attributes]})]) ==
               {:error, :invalid_trigger_document}
    end
  end

  test "rejects duplicate trigger IDs across documents" do
    first = loaded(%{"triggers" => [trigger("same", "first", "1m")]})
    second = loaded(%{"triggers" => [trigger("same", "second", "2m")]})
    assert Triggers.parse_documents([first, second]) == {:error, :duplicate_trigger}
  end

  test "rejects duplicate IDs across event and schedule triggers" do
    event = loaded(%{"triggers" => [trigger("same", "characters", "1m")]})
    schedule = loaded(%{"triggers" => [schedule_trigger("same", "0 0 * * *", "Etc/UTC")]})

    assert Triggers.parse_documents([event, schedule]) == {:error, :duplicate_trigger}
  end

  test "bounds the combined trigger category" do
    triggers = Enum.map(1..256, &trigger("trigger-#{&1}", "characters", "1m"))

    assert {:ok, %Triggers{triggers: parsed}} =
             Triggers.parse_documents([loaded(%{"triggers" => triggers})])

    assert map_size(parsed) == 256

    overflow_trigger = trigger("trigger-257", "characters", "1m")

    assert Triggers.parse_documents([loaded(%{"triggers" => triggers ++ [overflow_trigger]})]) ==
             {:error, :too_many_triggers}

    overflow = loaded(%{"triggers" => [overflow_trigger]})

    assert Triggers.parse_documents([loaded(%{"triggers" => triggers}), overflow]) ==
             {:error, :too_many_triggers}
  end

  test "rejects invalid document collections and improper trigger lists" do
    assert Triggers.parse_documents(nil) == {:error, :invalid_trigger_document}
    assert Triggers.parse_documents([%{}]) == {:error, :invalid_trigger_document}

    assert Triggers.parse_documents([loaded(%{"triggers" => []}) | :tail]) ==
             {:error, :invalid_trigger_document}

    assert Triggers.parse_documents([loaded(%{"triggers" => [%{} | :tail]})]) ==
             {:error, :invalid_trigger_document}
  end

  test "redacts trigger configuration from inspection" do
    trigger = %EventTrigger{
      id: "private-trigger",
      matcher: %ClusterMurmur.Events.Matcher{predicates: []},
      action: :start_conversation,
      binding: "private-binding",
      cooldown_ms: 1_000
    }

    schedule = %ScheduleTrigger{
      id: "private-schedule",
      cron: %Crontab.CronExpression{},
      timezone: "private/zone",
      action: :emit_event,
      event: %EmittedEvent{
        type: "private.event",
        group: "private-group",
        subject: "private-subject"
      }
    }

    set = %Triggers{triggers: %{"private-trigger" => trigger, "private-schedule" => schedule}}

    for inspected <- [inspect(trigger), inspect(schedule), inspect(schedule.event), inspect(set)] do
      refute inspected =~ "private"
      refute inspected =~ "binding"
    end
  end

  test "uses the configured embedded timezone database without runtime updates" do
    assert Calendar.get_time_zone_database() == TimeZoneInfo.TimeZoneDatabase
    assert Application.fetch_env!(:time_zone_info, :update) == :disabled
    assert TimeZoneInfo.state() == :ok
  end

  defp loaded(document), do: %LoadedDocument{path: "/config/triggers.yaml", document: document}

  defp trigger(id, binding, cooldown, predicates \\ [predicate("type", "exists")]) do
    %{
      "id" => id,
      "event" => %{"match" => %{"all" => predicates}},
      "action" => %{"type" => "start_conversation", "binding" => binding},
      "cooldown" => cooldown
    }
  end

  defp schedule_trigger(id, cron, timezone, group \\ "social") do
    %{
      "id" => id,
      "schedule" => %{"cron" => cron, "timezone" => timezone},
      "action" => %{
        "type" => "emit_event",
        "event" => %{
          "type" => "schedule.fired",
          "group" => group,
          "subject" => id
        }
      }
    }
  end

  defp predicate(field, operator), do: %{"field" => field, "operator" => operator}

  defp predicate(field, "in", values),
    do: %{"field" => field, "operator" => "in", "values" => values}

  defp predicate(field, operator, value),
    do: %{"field" => field, "operator" => operator, "value" => value}
end
