defmodule ClusterMurmur.Generation.FactProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Config.Presentation

  alias ClusterMurmur.Generation.{
    FactProjection,
    FactProjectionValidator,
    FactProjector
  }

  test "projects a fixed allowlist of application-confirmed event facts" do
    event =
      event(
        previous: %{"state" => "failed"},
        current: %{"state" => "healthy"},
        facts: %{"attempts" => 2, "checks" => [true, nil]},
        labels: %{"private-route" => "internal"},
        dedupe_key: "private-dedupe",
        correlation_key: "private-correlation",
        observed_at: ~U[2026-08-05 12:00:30.000000Z]
      )

    assert {:ok, %FactProjection{} = projection} = FactProjector.project(event)

    assert {:ok, prompt_facts} = FactProjectionValidator.to_prompt_map(projection)

    assert prompt_facts == %{
             "current_state" => %{"state" => "healthy"},
             "details" => %{"attempts" => 2, "checks" => [true, nil]},
             "event_type" => "observation.recovered",
             "group" => "recovery",
             "occurred_at" => "2026-08-05T12:00:00.000000Z",
             "occurred_at_timezone" => "Etc/UTC",
             "previous_state" => %{"state" => "failed"},
             "severity" => "info",
             "subject" => "example-target"
           }

    serialized = inspect(prompt_facts)

    for omitted <- [
          event.id,
          event.source,
          event.dedupe_key,
          event.correlation_key,
          "private-route",
          "internal",
          DateTime.to_iso8601(event.observed_at)
        ] do
      refute serialized =~ omitted
    end
  end

  test "omits absent optional facts from the prompt map" do
    assert {:ok, projection} =
             event(subject: nil, group: nil, severity: nil)
             |> FactProjector.project()

    assert {:ok, prompt_facts} = FactProjectionValidator.to_prompt_map(projection)

    assert prompt_facts == %{
             "details" => %{},
             "event_type" => "observation.recovered",
             "occurred_at" => "2026-08-05T12:00:00.000000Z",
             "occurred_at_timezone" => "Etc/UTC"
           }

    for omitted <- [
          "subject",
          "group",
          "severity",
          "previous_state",
          "current_state"
        ] do
      refute Map.has_key?(prompt_facts, omitted)
    end
  end

  test "omits every internal stochastic activation fact from generation" do
    activation =
      event(
        source: "stochastic",
        type: "stochastic.fired",
        subject: "internal-trigger",
        group: "internal-routing",
        severity: "info",
        facts: %{"prompt_field" => "internal"}
      )

    assert FactProjector.project_for_generation(activation, Presentation.default()) == {:ok, nil}
  end

  test "shifts only prompt-facing timestamps into the presentation timezone" do
    canonical = ~U[2026-08-15 12:00:00.000000Z]

    assert {:ok, projection} =
             FactProjector.project(
               event(occurred_at: canonical),
               %Presentation{timezone: "Asia/Tokyo"}
             )

    assert projection.occurred_at == canonical
    assert projection.occurred_at_timezone == "Asia/Tokyo"
    assert {:ok, prompt_facts} = FactProjectionValidator.to_prompt_map(projection)
    assert prompt_facts["occurred_at"] == "2026-08-15T21:00:00.000000+09:00"
    assert prompt_facts["occurred_at_timezone"] == "Asia/Tokyo"
  end

  test "uses embedded daylight-saving periods at the transition" do
    expectations = [
      {~U[2026-03-08 06:59:00.000000Z], "2026-03-08T01:59:00.000000-05:00"},
      {~U[2026-03-08 07:00:00.000000Z], "2026-03-08T03:00:00.000000-04:00"}
    ]

    for {canonical, expected} <- expectations do
      assert {:ok, projection} =
               FactProjector.project(
                 event(occurred_at: canonical),
                 %Presentation{timezone: "America/New_York"}
               )

      assert {:ok, prompt_facts} = FactProjectionValidator.to_prompt_map(projection)
      assert prompt_facts["occurred_at"] == expected
      assert prompt_facts["occurred_at_timezone"] == "America/New_York"
    end
  end

  test "rejects invalid events before projection" do
    for rejected <- [nil, %{}, %{event([]) | facts: []}, Map.put(event([]), :private, "value")] do
      result = FactProjector.project(rejected)
      assert result == {:error, :invalid_event}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects forged projections and non-JSON values" do
    valid = projection()

    for rejected <- [
          nil,
          %{},
          %{valid | event_type: ""},
          %{valid | details: []},
          %{valid | previous_state: :private},
          %{valid | occurred_at: %{valid.occurred_at | time_zone: "UTC"}},
          Map.delete(valid, :details),
          Map.put(valid, :private_value, "private")
        ] do
      result = FactProjectionValidator.validate(rejected)
      assert result == {:error, :invalid_fact_projection}
      refute inspect(result) =~ "private"
    end
  end

  test "bounds the actual escaped JSON representation" do
    escaped = String.duplicate(<<1>>, 12_000)
    event = event(facts: %{"escaped" => escaped})

    assert ClusterMurmur.Events.Validator.validate(event) == :ok
    assert FactProjector.project(event) == {:error, :invalid_fact_projection}
  end

  test "applies depth bounds to the actual outer prompt map" do
    accepted_details =
      Enum.reduce(1..6, %{}, fn depth, nested -> %{"level-#{depth}" => nested} end)

    rejected_details =
      Enum.reduce(1..7, %{}, fn depth, nested -> %{"level-#{depth}" => nested} end)

    assert {:ok, projection} = FactProjector.project(event(facts: accepted_details))
    assert {:ok, _prompt_facts} = FactProjectionValidator.to_prompt_map(projection)

    assert ClusterMurmur.Events.Validator.validate(event(facts: rejected_details)) == :ok

    assert FactProjector.project(event(facts: rejected_details)) ==
             {:error, :invalid_fact_projection}
  end

  test "projection inspection omits subject and supplied details" do
    assert {:ok, projection} =
             event(subject: "private-subject", facts: %{"private" => "value"})
             |> FactProjector.project()

    refute inspect(projection) =~ "private"
    assert inspect(projection) =~ "observation.recovered"
  end

  defp projection do
    %FactProjection{
      event_type: "observation.recovered",
      subject: "example-target",
      group: "recovery",
      severity: "info",
      previous_state: %{"state" => "failed"},
      current_state: %{"state" => "healthy"},
      details: %{},
      occurred_at: ~U[2026-08-05 12:00:00.000000Z],
      occurred_at_timezone: "Etc/UTC"
    }
  end

  defp event(overrides) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "private-event-id",
          type: "observation.recovered",
          source: "private-observer",
          subject: "example-target",
          group: "recovery",
          severity: "info",
          previous: nil,
          current: nil,
          occurred_at: ~U[2026-08-05 12:00:00.000000Z],
          observed_at: nil,
          dedupe_key: nil,
          correlation_key: nil,
          facts: %{},
          labels: %{}
        ],
        overrides
      )
    )
  end
end
