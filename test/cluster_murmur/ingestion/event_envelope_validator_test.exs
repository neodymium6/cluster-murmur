defmodule ClusterMurmur.Ingestion.EventEnvelopeValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventEnvelopeValidator}

  test "accepts one exact normalized event under its source policy" do
    assert EventEnvelopeValidator.validate(envelope(), configuration()) == :ok
  end

  test "rejects values outside every source-scoped allowlist" do
    changes = [
      {:source, "other-adapter"},
      {:type, "component.changed"},
      {:group, "ambient"},
      {:subject, "other-component"},
      {:severity, "emergency"},
      {:facts, %{"private" => true}},
      {:labels, %{"private" => "value"}}
    ]

    for {field, value} <- changes do
      assert envelope()
             |> Map.put(field, value)
             |> EventEnvelopeValidator.validate(configuration()) ==
               {:error, :invalid_external_event}
    end
  end

  test "keeps external facts flat and labels string-valued" do
    invalid = [
      %{envelope() | facts: %{"summary" => %{"nested" => "value"}}},
      %{envelope() | facts: %{"summary" => ["value"]}},
      %{envelope() | labels: %{"site" => 1}},
      %{envelope() | facts: %{"summary" => String.duplicate("x", 65_536)}}
    ]

    for value <- invalid do
      assert EventEnvelopeValidator.validate(value, configuration()) ==
               {:error, :invalid_external_event}
    end
  end

  test "rejects malformed identity, time, shape, and policy values" do
    invalid_envelopes = [
      %{envelope() | idempotency_key: "bad/key"},
      %{envelope() | idempotency_key: String.duplicate("x", 257)},
      %{envelope() | occurred_at: nil},
      Map.put(envelope(), :private, true),
      nil
    ]

    for value <- invalid_envelopes do
      assert EventEnvelopeValidator.validate(value, configuration()) ==
               {:error, :invalid_external_event}
    end

    assert EventEnvelopeValidator.validate(envelope(), ExternalIngestion.default()) ==
             {:error, :invalid_external_event}
  end

  test "inspection exposes neither identity nor supplied content" do
    inspected = inspect(envelope())

    assert inspected =~ "component.failed"
    refute inspected =~ "retry-identity"
    refute inspected =~ "example-component"
    refute inspected =~ "bounded summary"
    refute inspected =~ "example-site"
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
