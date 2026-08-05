defmodule ClusterMurmur.Generation.ProviderResultResolverTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.{PersonaProjection, ProviderResultResolver}

  test "returns normalized content for an accepted provider response" do
    assert ProviderResultResolver.resolve(
             {:ok, " Observer: The latest run completed. "},
             persona(),
             2_000
           ) == {:ok, {:llm, "The latest run completed."}}
  end

  test "chooses fallback for provider failures without exposing diagnostics" do
    for result <- [
          {:error, :authentication_failed},
          {:error, :invalid_request},
          {:error, :invalid_response},
          {:error, :rate_limited},
          {:error, :timeout},
          {:error, :unavailable},
          {:error, {:unexpected, "private-provider-diagnostic"}},
          {:unexpected, "private-provider-payload"}
        ] do
      decision = ProviderResultResolver.resolve(result, persona(), 2_000)
      assert decision == {:ok, :fallback}
      refute inspect(decision) =~ "private"
    end
  end

  test "chooses fallback when successful provider text is rejected" do
    for raw <- [
          "",
          "https://example.invalid",
          String.duplicate("a", 64 * 1_024 + 1),
          <<255>>
        ] do
      assert ProviderResultResolver.resolve({:ok, raw}, persona(), 2_000) ==
               {:ok, :fallback}
    end
  end

  test "rejects invalid orchestration inputs instead of masking them as fallback" do
    for {persona, limit} <- [
          {nil, 2_000},
          {%{persona() | display_name: ""}, 2_000},
          {persona(), 0},
          {persona(), 16 * 1_024 + 1},
          {persona(), 2.0}
        ] do
      assert ProviderResultResolver.resolve({:error, :timeout}, persona, limit) ==
               {:error, :invalid_provider_resolution}
    end
  end

  defp persona do
    %PersonaProjection{
      display_name: "Observer",
      instructions: "Speak briefly from supplied facts only."
    }
  end
end
