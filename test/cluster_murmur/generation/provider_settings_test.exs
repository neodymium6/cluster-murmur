defmodule ClusterMurmur.Generation.ProviderSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.ProviderSettings

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-provider-settings-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    api_key_path = Path.join(test_root, "api-key")
    File.write!(api_key_path, "clearly-fake-api-key-value\n")
    on_exit(fn -> File.rm_rf!(test_root) end)

    %{api_key_path: api_key_path}
  end

  test "loads bounded settings without exposing deployment values", context do
    environment = environment(context.api_key_path)

    assert {:ok, %ProviderSettings{} = settings} =
             ProviderSettings.load(valid_config(), environment)

    assert settings.provider == :openai_compatible
    assert settings.base_url == "https://llm.example.invalid/v1"
    assert settings.model == "example-model"
    assert settings.api_key == "clearly-fake-api-key-value"
    assert settings.timeout_ms == 20_000
    assert settings.max_output_tokens == 300

    inspected = inspect(settings)
    assert inspected =~ "provider: :openai_compatible"

    for hidden <- [settings.base_url, settings.model, settings.api_key] do
      refute inspected =~ hidden
    end
  end

  test "allows an operator-approved HTTP base URL", context do
    environment =
      environment(context.api_key_path, %{
        "LLM_BASE_URL" => " http://llm.example.invalid:11434/v1/ "
      })

    assert {:ok, settings} = ProviderSettings.load(valid_config(), environment)
    assert settings.base_url == "http://llm.example.invalid:11434/v1/"
  end

  test "accepts the complete valid TCP port range", context do
    for port <- [1, 65_535] do
      base_url = "https://llm.example.invalid:#{port}/v1"
      environment = environment(context.api_key_path, %{"LLM_BASE_URL" => base_url})

      assert {:ok, settings} = ProviderSettings.load(valid_config(), environment)
      assert settings.base_url == base_url
    end
  end

  test "requires an exact normalized public projection", context do
    oversized_config =
      Map.merge(
        valid_config(),
        Map.new(1..10_000, fn index -> {"forged-#{index}", "value"} end)
      )

    invalid = [
      nil,
      oversized_config,
      Map.delete(valid_config(), :model_env),
      Map.put(valid_config(), :extra, true),
      Map.put(valid_config(), :provider, :other),
      Map.put(valid_config(), :base_url_env, "INVALID-NAME"),
      Map.put(valid_config(), :model_env, nil),
      Map.put(valid_config(), :api_key_file_env, "1_API_KEY"),
      Map.put(valid_config(), :timeout_ms, 0),
      Map.put(valid_config(), :timeout_ms, 120_001),
      Map.put(valid_config(), :max_output_tokens, 0),
      Map.put(valid_config(), :max_output_tokens, 4_097)
    ]

    for config <- invalid do
      assert ProviderSettings.load(config, environment(context.api_key_path)) ==
               {:error, :invalid_provider_settings}
    end

    assert ProviderSettings.load(valid_config(), :not_an_environment_reader) ==
             {:error, :invalid_provider_settings}
  end

  test "rejects missing, malformed, empty, and oversized environment values", context do
    cases = [
      {%{"LLM_BASE_URL" => :missing}, :missing_provider_base_url},
      {%{"LLM_BASE_URL" => nil}, :invalid_provider_base_url},
      {%{"LLM_BASE_URL" => "  "}, :invalid_provider_base_url},
      {%{"LLM_BASE_URL" => String.duplicate("a", 2_049)}, :invalid_provider_base_url},
      {%{"LLM_MODEL" => :missing}, :missing_provider_model},
      {%{"LLM_MODEL" => nil}, :invalid_provider_model},
      {%{"LLM_MODEL" => "\n"}, :invalid_provider_model},
      {%{"LLM_MODEL" => String.duplicate("m", 257)}, :invalid_provider_model}
    ]

    for {overrides, reason} <- cases do
      assert ProviderSettings.load(
               valid_config(),
               environment(context.api_key_path, overrides)
             ) == {:error, reason}
    end
  end

  test "rejects base URLs outside the fixed HTTP boundary", context do
    invalid_urls = [
      "llm.example.invalid/v1",
      "ftp://llm.example.invalid/v1",
      "https://",
      "https://user@example.invalid/v1",
      "https://llm.example.invalid/v1?private=true",
      "https://llm.example.invalid/v1#fragment",
      "https://llm.example.invalid:0/v1",
      "https://llm.example.invalid:65536/v1",
      "https://llm.example.invalid/%ZZ",
      <<"https://llm.example.invalid/", 255>>
    ]

    for base_url <- invalid_urls do
      environment = environment(context.api_key_path, %{"LLM_BASE_URL" => base_url})

      assert ProviderSettings.load(valid_config(), environment) ==
               {:error, :invalid_provider_base_url}
    end
  end

  test "uses the bounded mounted-secret boundary for the API key", context do
    missing_environment = environment(context.api_key_path, %{"LLM_API_KEY_FILE" => :missing})

    assert ProviderSettings.load(valid_config(), missing_environment) ==
             {:error, {:api_key, :missing_secret_file_path}}

    empty_path = Path.join(Path.dirname(context.api_key_path), "empty")
    File.write!(empty_path, "\n")
    empty_environment = environment(empty_path)

    assert ProviderSettings.load(valid_config(), empty_environment) ==
             {:error, {:api_key, :empty_secret}}
  end

  test "fails closed when an injected environment reader raises" do
    assert ProviderSettings.load(valid_config(), fn _name -> raise "private diagnostic" end) ==
             {:error, :invalid_provider_settings}
  end

  defp valid_config do
    %{
      provider: :openai_compatible,
      base_url_env: "LLM_BASE_URL",
      model_env: "LLM_MODEL",
      api_key_file_env: "LLM_API_KEY_FILE",
      timeout_ms: 20_000,
      max_output_tokens: 300
    }
  end

  defp environment(api_key_path, overrides \\ %{}) do
    values =
      Map.merge(
        %{
          "LLM_BASE_URL" => "https://llm.example.invalid/v1",
          "LLM_MODEL" => "example-model",
          "LLM_API_KEY_FILE" => api_key_path
        },
        overrides
      )

    fn name ->
      case Map.fetch(values, name) do
        {:ok, :missing} -> :error
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end
  end
end
