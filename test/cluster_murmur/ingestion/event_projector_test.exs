defmodule ClusterMurmur.Ingestion.EventProjectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventProjector}

  test "derives a deterministic application-owned event identity" do
    assert {:ok, first} = EventProjector.project(envelope(), configuration())
    assert {:ok, second} = EventProjector.project(envelope(), configuration())

    assert first == second
    assert first.id =~ ~r/^external-[0-9a-f]{64}$/
    assert first.dedupe_key =~ ~r/^external:[0-9a-f]{64}$/

    assert String.replace_prefix(first.id, "external-", "") ==
             String.replace_prefix(first.dedupe_key, "external:", "")

    assert first.source == "alert-adapter"
    assert first.previous == nil
    assert first.current == nil
    assert first.observed_at == nil
    assert first.correlation_key == nil
    assert first.facts == %{"state" => "failed", "summary" => "bounded summary"}
  end

  test "scopes identity to source and idempotency key, not supplied content" do
    assert {:ok, original} = EventProjector.project(envelope(), configuration())

    changed = %{envelope() | facts: %{"state" => "failed", "summary" => "changed"}}
    assert {:ok, changed_event} = EventProjector.project(changed, configuration())
    assert changed_event.id == original.id
    refute changed_event == original

    retry = %{envelope() | idempotency_key: "another-retry"}
    assert {:ok, retry_event} = EventProjector.project(retry, configuration())
    refute retry_event.id == original.id
  end

  test "normalizes valid occurrence precision for durable equality" do
    occurred_at = %{~U[2026-08-30 15:00:00.123456Z] | microsecond: {123_456, 3}}

    assert {:ok, event} =
             envelope()
             |> Map.put(:occurred_at, occurred_at)
             |> EventProjector.project(configuration())

    assert event.occurred_at.microsecond == {123_456, 6}
  end

  test "rejects invalid envelopes and disabled configuration without projection" do
    assert EventProjector.project(%{envelope() | subject: "other"}, configuration()) ==
             {:error, :invalid_external_event}

    assert EventProjector.project(envelope(), ExternalIngestion.default()) ==
             {:error, :invalid_external_event}

    assert EventProjector.project(%{}, configuration()) ==
             {:error, :invalid_external_event}
  end

  defp envelope do
    %EventEnvelope{
      idempotency_key: "retry-identity",
      type: "component.failed",
      source: "alert-adapter",
      subject: "example-component",
      group: "operations",
      severity: "warning",
      occurred_at: ~U[2026-08-30 15:00:00.000000Z],
      facts: %{"state" => "failed", "summary" => "bounded summary"},
      labels: %{"site" => "example-site"}
    }
  end

  defp configuration do
    {:ok, configuration} =
      ExternalIngestion.parse(%{
        "sources" => %{
          "alert-adapter" => %{
            "event_types" => ["component.failed", "component.recovered"],
            "groups" => ["operations"],
            "subjects" => ["example-component"],
            "fact_keys" => ["state", "summary"],
            "label_keys" => ["site"]
          }
        }
      })

    configuration
  end
end
