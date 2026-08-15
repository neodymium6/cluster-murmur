defmodule ClusterMurmur.Runtime.OperationalTelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ClusterMurmur.Discord.WebhookHTTPTransport
  alias ClusterMurmur.Discord.WebhookResponse

  alias ClusterMurmur.Generation.{
    OpenAICompatibleHTTPTransport,
    OpenAICompatibleResponse,
    PersonaProjection,
    ProviderResultResolver
  }

  alias ClusterMurmur.Observers.MCPHTTPTransport
  alias ClusterMurmur.Runtime.OperationalTelemetry

  def handle_event(name, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, name, measurements, metadata})
  end

  test "emits one fixed cycle metric and a redacted structured log" do
    attach([:cluster_murmur, :runtime, :cycle, :stop])
    started_at = System.monotonic_time()

    log =
      capture_log(fn ->
        assert OperationalTelemetry.cycle(:poll, started_at, :poll_failed) == :ok
      end)

    assert_receive {:telemetry, [:cluster_murmur, :runtime, :cycle, :stop], measurements,
                    metadata}

    assert measurements.count == 1
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata == %{component: :poll, outcome: :error, error_class: :poll_failed}
    assert log =~ "runtime cycle completed"
  end

  test "instruments every fixed live transport without exposing arguments" do
    attach([:cluster_murmur, :external, :request, :stop])
    secret = "must-not-appear"

    log =
      capture_log(fn ->
        assert MCPHTTPTransport.execute(secret, nil) ==
                 {:error, :rejected, :invalid_request}

        assert OpenAICompatibleHTTPTransport.execute(secret, nil) ==
                 {:error, :invalid_response}

        assert WebhookHTTPTransport.execute(secret, nil) ==
                 {:error, :not_sent, :invalid_request}
      end)

    assert_external(:observer_mcp, :rejected, :invalid_request)
    assert_external(:model_provider, :error, :invalid_response)
    assert_external(:discord_webhook, :not_sent, :invalid_request)
    assert log =~ "external request completed"
    refute log =~ secret
  end

  test "ignores caller-selected dimensions and never inspects invalid results" do
    attach([:cluster_murmur, :runtime, :cycle, :stop])
    attach([:cluster_murmur, :external, :request, :stop])
    secret = "must-not-appear"

    log =
      capture_log(fn ->
        assert OperationalTelemetry.cycle(:caller_selected, System.monotonic_time(), nil) == :ok

        assert OperationalTelemetry.external_request(
                 {:error, secret},
                 :caller_selected,
                 System.monotonic_time()
               ) == {:error, secret}

        assert OperationalTelemetry.external_request(
                 {:error, :rejected, :rate_limited},
                 :discord_webhook,
                 System.monotonic_time()
               ) == {:error, :rejected, :rate_limited}
      end)

    refute_receive {:telemetry, _event, _measurements, _metadata}
    refute log =~ secret
  end

  test "records success without inspecting the returned value" do
    attach([:cluster_murmur, :external, :request, :stop])

    result =
      {:ok,
       %OpenAICompatibleResponse{
         status: 200,
         body: ~s({"choices":[{"message":{"content":"must-not-appear"}}]})
       }}

    log =
      capture_log(fn ->
        assert OperationalTelemetry.external_request(
                 result,
                 :model_provider,
                 System.monotonic_time()
               ) == result
      end)

    assert_external(:model_provider, :ok, nil)
    assert log =~ "external request completed"
    refute log =~ "must-not-appear"
  end

  test "classifies known non-success HTTP responses without logging their bodies" do
    attach([:cluster_murmur, :external, :request, :stop])
    started_at = System.monotonic_time()

    provider = {:ok, %OpenAICompatibleResponse{status: 401, body: "must-not-appear"}}
    discord = {:ok, %WebhookResponse{status: 500, body: "must-not-appear"}}

    log =
      capture_log(fn ->
        assert OperationalTelemetry.external_request(provider, :model_provider, started_at) ==
                 provider

        assert OperationalTelemetry.external_request(discord, :discord_webhook, started_at) ==
                 discord
      end)

    assert_external(:model_provider, :rejected, :authentication_failed)
    assert_external(:discord_webhook, :unknown, :unavailable)
    refute log =~ "must-not-appear"
  end

  test "reports token exhaustion without logging response content or usage payloads" do
    attach([:cluster_murmur, :external, :request, :stop])

    result =
      {:ok,
       %OpenAICompatibleResponse{
         status: 200,
         body:
           ~s({"choices":[{"finish_reason":"length","message":{"content":"  "}}],"usage":{"completion_tokens":32768,"completion_tokens_details":{"reasoning_tokens":32768}},"private":"must-not-appear"})
       }}

    log =
      capture_log(fn ->
        assert OperationalTelemetry.external_request(
                 result,
                 :model_provider,
                 System.monotonic_time()
               ) == result
      end)

    assert_external(:model_provider, :error, :token_exhausted)
    assert log =~ "error_class=token_exhausted"
    refute log =~ "32768"
    refute log =~ "must-not-appear"
  end

  test "reports accepted and fallback generation decisions without content" do
    attach([:cluster_murmur, :generation, :decision])

    log =
      capture_log(fn ->
        assert OperationalTelemetry.generation_decision({:llm, "must-not-appear"}) ==
                 {:llm, "must-not-appear"}

        assert OperationalTelemetry.generation_decision({:fallback, :provider_failure}) ==
                 {:fallback, :provider_failure}
      end)

    assert_generation(:accepted, nil)
    assert_generation(:fallback, :provider_failure)
    assert log =~ "generation decision completed"
    refute log =~ "must-not-appear"
  end

  test "reports accepted network-looking output without leaking provider content" do
    attach([:cluster_murmur, :generation, :decision])
    private_output = "https://private.example.invalid/must-not-appear"

    response = %OpenAICompatibleResponse{
      status: 200,
      body: Jason.encode!(%{"choices" => [%{"message" => %{"content" => private_output}}]})
    }

    assert {:ok, ^private_output} = OpenAICompatibleResponse.decode(response)

    assert {:ok, decision} =
             ProviderResultResolver.resolve(
               {:ok, private_output},
               %PersonaProjection{
                 display_name: "Observer",
                 instructions: "Speak briefly from supplied facts only."
               },
               2_000
             )

    assert decision == {:llm, private_output}

    log =
      capture_log(fn ->
        assert OperationalTelemetry.generation_decision(decision) == decision
      end)

    assert_generation(:accepted, nil)
    refute log =~ "error_class="
    refute log =~ private_output
    refute log =~ "must-not-appear"
  end

  test "ignores arbitrary generation decisions without inspecting them" do
    attach([:cluster_murmur, :generation, :decision])
    secret = "must-not-appear"

    log =
      capture_log(fn ->
        assert OperationalTelemetry.generation_decision({:fallback, secret}) ==
                 {:fallback, secret}

        assert OperationalTelemetry.generation_decision({:caller_selected, secret}) ==
                 {:caller_selected, secret}
      end)

    refute_receive {:telemetry, _event, _measurements, _metadata}
    refute log =~ secret
  end

  defp assert_external(component, outcome, error_class) do
    assert_receive {:telemetry, [:cluster_murmur, :external, :request, :stop], measurements,
                    metadata}

    assert measurements.count == 1
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata == %{component: component, outcome: outcome, error_class: error_class}
  end

  defp assert_generation(outcome, error_class) do
    assert_receive {:telemetry, [:cluster_murmur, :generation, :decision], %{count: 1}, metadata}

    assert metadata == %{
             component: :model_generation,
             outcome: outcome,
             error_class: error_class
           }
  end

  defp attach(event) do
    handler = {__MODULE__, self(), event}

    :ok =
      :telemetry.attach(
        handler,
        event,
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
