defmodule ClusterMurmur.Ingestion.EventEnvelopeDecoderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventEnvelopeDecoder}

  test "decodes one exact allowlisted normalized JSON event" do
    assert {:ok, %EventEnvelope{} = envelope} =
             EventEnvelopeDecoder.decode(encode(document()), configuration())

    assert envelope.idempotency_key == "retry-identity"
    assert envelope.type == "component.failed"
    assert envelope.source == "alert-adapter"
    assert envelope.occurred_at == ~U[2026-08-30 15:00:00.000000Z]
    assert envelope.facts == %{"state" => "failed", "summary" => "bounded summary"}
    assert envelope.labels == %{"site" => "example-site"}
  end

  test "rejects missing, unknown, duplicate, and trailing document input" do
    body = encode(document())

    duplicate =
      String.replace(
        body,
        ~s("idempotency_key":"retry-identity"),
        ~s("idempotency_key":"retry-identity","idempotency_key":"other"),
        global: false
      )

    refute duplicate == body

    invalid = [
      document() |> Map.delete("group") |> encode(),
      document() |> Map.put("private", true) |> encode(),
      duplicate,
      body <> "{}",
      "[]",
      "not-json"
    ]

    for candidate <- invalid do
      assert EventEnvelopeDecoder.decode(candidate, configuration()) ==
               {:error, :invalid_external_event_body}
    end
  end

  test "requires a canonical zero-offset occurrence time" do
    invalid = [
      "2026-08-30T17:00:00+02:00",
      "2026-08-30T15:00:00",
      "not-a-time",
      nil
    ]

    for occurred_at <- invalid do
      body = document() |> Map.put("occurred_at", occurred_at) |> encode()

      assert EventEnvelopeDecoder.decode(body, configuration()) ==
               {:error, :invalid_external_event_body}
    end

    body = document() |> Map.put("occurred_at", "2026-08-30T15:00:00+00:00") |> encode()
    assert {:ok, envelope} = EventEnvelopeDecoder.decode(body, configuration())
    assert envelope.occurred_at.time_zone == "Etc/UTC"
  end

  test "applies flat-value schema and source-scoped allowlists" do
    invalid = [
      Map.put(document(), "source", "other-adapter"),
      Map.put(document(), "subject", "other-component"),
      Map.put(document(), "facts", %{"private" => true}),
      Map.put(document(), "facts", %{"state" => %{"nested" => true}}),
      Map.put(document(), "labels", %{"site" => 1})
    ]

    for candidate <- invalid do
      assert EventEnvelopeDecoder.decode(encode(candidate), configuration()) ==
               {:error, :invalid_external_event_body}
    end
  end

  test "enforces a complete 64 KiB body limit before decoding" do
    assert EventEnvelopeDecoder.decode("", configuration()) ==
             {:error, :invalid_external_event_body}

    assert EventEnvelopeDecoder.decode(String.duplicate(" ", 64 * 1_024 + 1), configuration()) ==
             {:error, :invalid_external_event_body}

    assert EventEnvelopeDecoder.decode(encode(document()), ExternalIngestion.default()) ==
             {:error, :invalid_external_event_body}
  end

  defp document do
    %{
      "idempotency_key" => "retry-identity",
      "type" => "component.failed",
      "source" => "alert-adapter",
      "subject" => "example-component",
      "group" => "operations",
      "severity" => "warning",
      "occurred_at" => "2026-08-30T15:00:00.000000Z",
      "facts" => %{"state" => "failed", "summary" => "bounded summary"},
      "labels" => %{"site" => "example-site"}
    }
  end

  defp configuration do
    {:ok, configuration} =
      ExternalIngestion.parse(%{
        "sources" => %{
          "alert-adapter" => %{
            "event_types" => ["component.failed"],
            "groups" => ["operations"],
            "subjects" => ["example-component"],
            "fact_keys" => ["state", "summary"],
            "label_keys" => ["site"]
          }
        }
      })

    configuration
  end

  defp encode(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
