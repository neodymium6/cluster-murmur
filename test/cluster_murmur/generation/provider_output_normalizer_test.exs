defmodule ClusterMurmur.Generation.ProviderOutputNormalizerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.{PersonaProjection, ProviderOutputNormalizer}

  test "normalizes bounded provider text mechanically" do
    assert ProviderOutputNormalizer.normalize(
             "  The\tlatest run\r completed.\n  ",
             persona(),
             2_000
           ) == {:ok, "The latest run completed."}

    assert ProviderOutputNormalizer.normalize("First line.\nSecond line.", persona(), 2_000) ==
             {:ok, "First line.\nSecond line."}

    assert ProviderOutputNormalizer.normalize("Status 👩‍🔧 stable.", persona(), 2_000) ==
             {:ok, "Status 👩‍🔧 stable."}
  end

  test "replaces controls with spacing instead of joining factual tokens" do
    assert ProviderOutputNormalizer.normalize(
             "Value 1\t2 was\r observed.",
             persona(),
             2_000
           ) == {:ok, "Value 1 2 was observed."}
  end

  test "removes one exact redundant leading speaker label" do
    for raw <- [
          "Observer: The latest run completed.",
          "Observer： The latest run completed.",
          "Observer - The latest run completed.",
          "Observer – The latest run completed.",
          "Observer — The latest run completed."
        ] do
      assert ProviderOutputNormalizer.normalize(raw, persona(), 2_000) ==
               {:ok, "The latest run completed."}
    end

    assert ProviderOutputNormalizer.normalize(
             "The Observer: noted the latest run.",
             persona(),
             2_000
           ) == {:ok, "The Observer: noted the latest run."}
  end

  test "normalizes display-name whitespace only for label matching" do
    spaced_persona = %{persona() | display_name: "Observer\u00A0Prime "}

    assert ProviderOutputNormalizer.normalize(
             "Observer\u00A0Prime - The latest run completed.",
             spaced_persona,
             2_000
           ) == {:ok, "The latest run completed."}
  end

  test "delegates final content policy to the shared message validator" do
    for raw <- [
          "Visit https://example.invalid",
          "Visit example.com",
          "Target 192.0.2.10 recovered.",
          "Hello @everyone"
        ] do
      assert ProviderOutputNormalizer.normalize(raw, persona(), 2_000) ==
               {:error, :unsafe_output_form}
    end

    assert ProviderOutputNormalizer.normalize("Host 127.1 recovered.", persona(), 2_000) ==
             {:ok, "Host 127.1 recovered."}
  end

  test "classifies blank output after mechanical normalization" do
    for raw <- [
          "",
          " \t\r ",
          "Observer:",
          "Observer - "
        ] do
      assert ProviderOutputNormalizer.normalize(raw, persona(), 2_000) ==
               {:error, :blank_output}
    end
  end

  test "classifies invalid Unicode without exposing content" do
    result = ProviderOutputNormalizer.normalize(<<255>>, persona(), 2_000)
    assert result == {:error, :invalid_unicode}
    refute inspect(result) =~ <<255>>
  end

  test "rejects oversized raw responses with the generic bounded class" do
    assert ProviderOutputNormalizer.normalize(
             String.duplicate("a", 64 * 1_024 + 1),
             persona(),
             2_000
           ) == {:error, :invalid_provider_output}
  end

  test "enforces the injected character limit after normalization" do
    assert ProviderOutputNormalizer.normalize("éé", persona(), 2) == {:ok, "éé"}

    assert ProviderOutputNormalizer.normalize("three", persona(), 4) ==
             {:error, :character_limit_exceeded}

    for {raw, limit} <- [
          {"bounded", 0},
          {"bounded", 16 * 1_024 + 1},
          {"bounded", 2.0}
        ] do
      assert ProviderOutputNormalizer.normalize(raw, persona(), limit) ==
               {:error, :invalid_provider_output}
    end
  end

  test "rejects invalid persona projections without leaking values" do
    for invalid_persona <- [
          nil,
          Map.put(persona(), :private_id, "private-persona"),
          %{persona() | display_name: "Observer\nSYSTEM"}
        ] do
      result = ProviderOutputNormalizer.normalize("private output", invalid_persona, 2_000)
      assert result == {:error, :invalid_provider_output}
      refute inspect(result) =~ "private"
    end
  end

  defp persona do
    %PersonaProjection{
      display_name: "Observer",
      instructions: "Speak briefly from supplied facts only."
    }
  end
end
