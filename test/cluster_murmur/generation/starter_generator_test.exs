defmodule ClusterMurmur.Generation.StarterGeneratorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.StarterGenerator
  alias ClusterMurmur.Generation.StarterGenerator.Generated
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @inserted_at ~U[2026-08-07 02:00:01.000000Z]

  defmodule FakeProvider do
    def generate(request, settings, transport) do
      Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, 0) + 1)
      Process.put({__MODULE__, :request}, request)
      Process.put({__MODULE__, :settings}, settings)
      transport.(request)
    end
  end

  defmodule RaisingProvider do
    def generate(_request, _settings, _transport), do: raise("private provider diagnostic")
  end

  setup do
    for key <- [:calls, :request, :settings], do: Process.delete({FakeProvider, key})
    :ok
  end

  test "calls one injected provider and returns a validated unpublished LLM message" do
    configuration = RuntimeFixture.configuration()
    plan = RuntimeFixture.generation_plan(configuration)
    settings = RuntimeFixture.provider_settings()
    transport = fn _request -> {:ok, " Caretaker: A bounded confirmed event occurred. "} end

    assert {:ok, %Generated{} = generated} =
             StarterGenerator.generate(
               plan,
               configuration,
               %{},
               settings,
               @inserted_at,
               FakeProvider,
               transport
             )

    assert Process.get({FakeProvider, :calls}) == 1
    assert Process.get({FakeProvider, :request}) === plan.request
    assert Process.get({FakeProvider, :settings}) === settings
    assert generated.plan === plan
    assert generated.message.conversation_id == "conversation-1"
    assert generated.message.persona_id == "caretaker"
    assert generated.message.origin == :llm
    assert generated.message.content == "A bounded confirmed event occurred."
    assert generated.message.discord_message_id == nil
    assert generated.message.inserted_at == @inserted_at
    assert StarterGenerator.validate(generated, configuration, %{}) == :ok

    refute inspect(generated) =~ "private fact"
    refute inspect(generated) =~ "clearly-fake-api-key"
  end

  test "uses deterministic fallback for provider failures and structurally rejected output" do
    configuration = RuntimeFixture.configuration()
    plan = RuntimeFixture.generation_plan(configuration)
    settings = RuntimeFixture.provider_settings()

    for transport <- [
          fn _request -> {:error, :timeout} end,
          fn _request -> {:ok, <<255>>} end
        ] do
      assert {:ok, generated} =
               StarterGenerator.generate(
                 plan,
                 configuration,
                 %{},
                 settings,
                 @inserted_at,
                 FakeProvider,
                 transport
               )

      assert generated.message.origin == :fallback
      assert generated.message.content == "A confirmed event was recorded."
    end

    assert {:ok, generated} =
             StarterGenerator.generate(
               plan,
               configuration,
               %{},
               settings,
               @inserted_at,
               RaisingProvider,
               fn _request -> flunk("transport must not run") end
             )

    assert generated.message.origin == :fallback
    assert generated.message.content == "A confirmed event was recorded."
  end

  test "rejects orchestration inputs before any provider call" do
    configuration = RuntimeFixture.configuration()
    plan = RuntimeFixture.generation_plan(configuration)
    settings = RuntimeFixture.provider_settings()
    transport = fn _request -> flunk("transport must not run") end

    cases = [
      {Map.put(plan, :private, true), configuration, settings, @inserted_at, FakeProvider},
      {plan, nil, settings, @inserted_at, FakeProvider},
      {plan, configuration, %{settings | api_key: "bad\r\nheader"}, @inserted_at, FakeProvider},
      {plan, configuration, %{settings | timeout_ms: 120_000}, @inserted_at, FakeProvider},
      {plan, configuration, %{settings | max_output_tokens: 4_096}, @inserted_at, FakeProvider},
      {plan, configuration, %{settings | reasoning_effort: :low}, @inserted_at, FakeProvider},
      {plan, configuration, settings, ~U[2026-08-07 01:59:59.000000Z], FakeProvider},
      {plan, configuration, settings, @inserted_at, String}
    ]

    for {candidate_plan, candidate_configuration, candidate_settings, at, provider} <- cases do
      assert {:error, _reason} =
               StarterGenerator.generate(
                 candidate_plan,
                 candidate_configuration,
                 %{},
                 candidate_settings,
                 at,
                 provider,
                 transport
               )
    end

    assert Process.get({FakeProvider, :calls}) == nil
  end

  test "revalidates exact message correlation without retaining provider settings" do
    configuration = RuntimeFixture.configuration()
    plan = RuntimeFixture.generation_plan(configuration)

    assert {:ok, generated} =
             StarterGenerator.generate(
               plan,
               configuration,
               %{},
               RuntimeFixture.provider_settings(),
               @inserted_at,
               FakeProvider,
               fn _request -> {:ok, "A bounded fact."} end
             )

    for forged <- [
          nil,
          Map.put(generated, :private, true),
          %{generated | message: %{generated.message | conversation_id: "other"}},
          %{generated | message: %{generated.message | persona_id: "other"}},
          %{generated | message: %{generated.message | discord_message_id: "123"}},
          %{generated | plan: %{plan | request: %{plan.request | conversation: [%{}]}}}
        ] do
      assert StarterGenerator.validate(forged, configuration, %{}) ==
               {:error, :invalid_starter_message}
    end
  end

  test "revalidates message time against a later observed event instant" do
    configuration = RuntimeFixture.configuration()

    event =
      RuntimeFixture.event(observed_at: ~U[2026-08-07 02:00:02.000000Z])

    plan = RuntimeFixture.generation_plan(configuration, event)

    assert {:ok, generated} =
             StarterGenerator.generate(
               plan,
               configuration,
               %{},
               RuntimeFixture.provider_settings(),
               ~U[2026-08-07 02:00:03.000000Z],
               FakeProvider,
               fn _request -> {:ok, "A bounded fact."} end
             )

    forged = %{
      generated
      | message: %{generated.message | inserted_at: ~U[2026-08-07 02:00:01.000000Z]}
    }

    assert StarterGenerator.validate(forged, configuration, %{}) ==
             {:error, :invalid_starter_message}
  end
end
