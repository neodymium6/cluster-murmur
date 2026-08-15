defmodule ClusterMurmur.Discord.WebhookRequestTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Discord.{PublicationPlanner, WebhookRequest, WebhookSettings}
  alias ClusterMurmur.Persistence.MessageRecord
  alias ClusterMurmur.Personas.Persona

  test "encodes one fixed bounded webhook request" do
    record = loaded()
    persona = persona()
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)

    assert {:ok, %WebhookRequest{} = request} =
             WebhookRequest.encode(plan, record, persona, settings)

    assert request.method == :post
    assert request.url == webhook_url()
    assert request.headers == [{"content-type", "application/json"}]
    assert request.query == [{"wait", "true"}]
    assert request.connect_timeout_ms == 5_000
    assert request.receive_timeout_ms == 10_000
    assert request.overall_timeout_ms == 15_000
    assert request.max_response_bytes == 16 * 1_024

    assert request.json == %{
             "allowed_mentions" => %{"parse" => []},
             "content" => "A bounded confirmed fact.",
             "username" => "Observer"
           }
  end

  test "includes only one validated avatar override" do
    record = loaded()
    persona = persona(avatar: "https://example.com/avatar.png")
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)

    assert {:ok, request} = WebhookRequest.encode(plan, record, persona, settings)
    assert request.json["avatar_url"] == "https://example.com/avatar.png"
  end

  test "requires an exact plan revalidated against independent current inputs" do
    record = loaded()
    persona = persona()
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)

    invalid_calls = [
      {nil, record, persona, settings},
      {%{plan | payload: %{plan.payload | allowed_mentions: %{parse: ["everyone"]}}}, record,
       persona, settings},
      {plan, loaded(content: "Changed fact."), persona, settings},
      {plan, record, persona(display_name: "Changed"), settings},
      {plan, record, persona, other_settings()}
    ]

    for {candidate, current_record, current_persona, current_settings} <- invalid_calls do
      assert WebhookRequest.encode(
               candidate,
               current_record,
               current_persona,
               current_settings
             ) == {:error, :invalid_publication_plan}
    end
  end

  test "rejects every forged request field before transport" do
    record = loaded()
    persona = persona()
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)
    assert {:ok, request} = WebhookRequest.encode(plan, record, persona, settings)
    assert WebhookRequest.validate(request, plan, record, persona, settings) == :ok
    assert WebhookRequest.validate_for_transport(request, settings) == :ok

    forged = [
      %{request | method: :get},
      %{request | url: other_webhook_url()},
      %{request | headers: [{"authorization", "forged"}]},
      %{request | query: [{"wait", "false"}]},
      %{request | json: %{"content" => "forged"}},
      %{request | connect_timeout_ms: 60_000},
      %{request | receive_timeout_ms: 60_000},
      %{request | overall_timeout_ms: 60_000},
      %{request | max_response_bytes: 1_000_000},
      Map.put(request, :arbitrary_http_option, true)
    ]

    for candidate <- forged do
      assert WebhookRequest.validate(candidate, plan, record, persona, settings) ==
               {:error, :invalid_webhook_request}

      assert WebhookRequest.validate_for_transport(candidate, settings) ==
               {:error, :invalid_webhook_request}
    end
  end

  test "revalidates only the fixed safe payload at the transport boundary" do
    record = loaded()
    persona = persona(avatar: "https://example.com/avatar.png")
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)
    assert {:ok, request} = WebhookRequest.encode(plan, record, persona, settings)

    forged_payloads = [
      Map.put(request.json, "extra", true),
      put_in(request.json, ["allowed_mentions", "parse"], ["everyone"]),
      %{request.json | "username" => String.duplicate("x", 81)},
      %{request.json | "avatar_url" => nil},
      %{request.json | "avatar_url" => "http://example.com/avatar.png"}
    ]

    for payload <- forged_payloads do
      assert WebhookRequest.validate_for_transport(%{request | json: payload}, settings) ==
               {:error, :invalid_webhook_request}
    end

    mention_payload = %{request.json | "content" => "Hello @everyone and <@123>"}
    assert mention_payload["allowed_mentions"] == %{"parse" => []}

    assert WebhookRequest.validate_for_transport(%{request | json: mention_payload}, settings) ==
             :ok

    assert WebhookRequest.validate_for_transport(request, other_settings()) ==
             {:error, :invalid_webhook_request}
  end

  test "inspection and errors hide content, identity, and webhook credential" do
    record = loaded(content: "Private approved observation.")
    persona = persona(display_name: "Private Persona")
    settings = settings()
    assert {:ok, plan} = PublicationPlanner.plan(record, persona, settings)
    assert {:ok, request} = WebhookRequest.encode(plan, record, persona, settings)

    result = WebhookRequest.encode(%{plan | payload: nil}, record, persona, settings)

    for inspected <- [inspect(request), inspect(result)] do
      for hidden <- ["Private", "approved observation", "fake-token", "discord.com"] do
        refute inspected =~ hidden
      end
    end
  end

  defp loaded(overrides \\ []) do
    struct!(
      MessageRecord,
      Keyword.merge(
        [
          __meta__: Ecto.put_meta(%MessageRecord{}, state: :loaded).__meta__,
          id: 1,
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: :llm,
          content: "A bounded confirmed fact.",
          discord_message_id: nil,
          inserted_at: ~U[2026-08-05 12:01:00.000000Z]
        ],
        overrides
      )
    )
  end

  defp persona(overrides \\ []) do
    struct!(
      Persona,
      Keyword.merge(
        [
          id: "observer",
          display_name: "Observer",
          avatar: nil,
          prompt: "Use only supplied facts.",
          enabled: true,
          interests: %{},
          behavior: %{},
          relationships: %{},
          metadata: %{}
        ],
        overrides
      )
    )
  end

  defp settings, do: %WebhookSettings{url: webhook_url()}
  defp other_settings, do: %WebhookSettings{url: other_webhook_url()}

  defp webhook_url,
    do: Enum.join(["https://", "discord", ".", "com", "/api/webhooks/1/fake-token"])

  defp other_webhook_url,
    do: Enum.join(["https://", "discord", ".", "com", "/api/webhooks/2/other-fake-token"])
end
