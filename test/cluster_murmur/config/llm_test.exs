defmodule ClusterMurmur.Config.LLMTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.LLM

  test "parses the exact bounded public provider configuration" do
    assert {:ok, %LLM{} = llm} = LLM.parse(valid_document())

    assert llm.provider == :openai_compatible
    assert llm.base_url_env == "CLUSTER_MURMUR_LLM_BASE_URL"
    assert llm.model_env == "CLUSTER_MURMUR_LLM_MODEL"
    assert llm.api_key_file_env == "CLUSTER_MURMUR_LLM_API_KEY_FILE"
    assert llm.timeout_ms == 20_000
    assert llm.max_output_tokens == 300
    assert llm.reasoning_effort == nil
    assert LLM.validate(llm) == :ok

    assert LLM.to_provider_settings_projection(llm) ==
             {:ok,
              %{
                provider: :openai_compatible,
                base_url_env: "CLUSTER_MURMUR_LLM_BASE_URL",
                model_env: "CLUSTER_MURMUR_LLM_MODEL",
                api_key_file_env: "CLUSTER_MURMUR_LLM_API_KEY_FILE",
                timeout_ms: 20_000,
                max_output_tokens: 300,
                reasoning_effort: nil
              }}
  end

  test "accepts only closed optional reasoning efforts" do
    for {encoded, normalized} <- [
          {"none", :none},
          {"minimal", :minimal},
          {"low", :low},
          {"medium", :medium},
          {"high", :high},
          {"xhigh", :xhigh},
          {"max", :max}
        ] do
      assert {:ok, %LLM{reasoning_effort: ^normalized} = llm} =
               LLM.parse(valid_document(%{"reasoning_effort" => encoded}))

      assert {:ok, document} = LLM.to_document(llm)
      assert document["reasoning_effort"] == encoded
    end

    assert {:ok, default} = LLM.parse(valid_document())
    assert {:ok, document} = LLM.to_document(default)
    refute Map.has_key?(document, "reasoning_effort")

    for value <- [nil, "", "default", "LOW", :low, 1] do
      assert LLM.parse(valid_document(%{"reasoning_effort" => value})) ==
               {:error, :invalid_llm_configuration}
    end
  end

  test "requires the fixed provider and exact public fields" do
    oversized =
      Map.merge(
        valid_document(),
        Map.new(1..10_000, fn index -> {"forged-#{index}", "value"} end)
      )

    invalid = [
      nil,
      %{},
      Map.delete(valid_document(), "model_env"),
      Map.put(valid_document(), "private_endpoint", "https://private.example.invalid"),
      Map.put(valid_document(), "provider", "other"),
      Map.put(valid_document(), "base_url_env", "INVALID-NAME"),
      Map.put(valid_document(), "model_env", 1),
      Map.put(valid_document(), "api_key_file_env", "1_API_KEY"),
      oversized
    ]

    for document <- invalid do
      assert LLM.parse(document) == {:error, :invalid_llm_configuration}
    end
  end

  test "bounds timeout syntax and output tokens before conversion" do
    invalid = [
      Map.put(valid_document(), "timeout", "0s"),
      Map.put(valid_document(), "timeout", "120001ms"),
      Map.put(valid_document(), "timeout", "2m1s"),
      Map.put(valid_document(), "timeout", String.duplicate("9", 100_000) <> "ms"),
      Map.put(valid_document(), "max_output_tokens", 0),
      Map.put(valid_document(), "max_output_tokens", 32_769),
      Map.put(valid_document(), "max_output_tokens", 300.0)
    ]

    for document <- invalid do
      assert LLM.parse(document) == {:error, :invalid_llm_configuration}
    end

    assert {:ok, %LLM{timeout_ms: 120_000, max_output_tokens: 32_768}} =
             LLM.parse(valid_document(%{"timeout" => "2m", "max_output_tokens" => 32_768}))
  end

  test "rejects forged normalized values and redacts environment names" do
    assert {:ok, llm} = LLM.parse(valid_document())

    forged = [
      %{llm | provider: :other},
      %{llm | timeout_ms: 0},
      %{llm | reasoning_effort: :unsupported},
      Map.put(llm, :private, true)
    ]

    for value <- forged do
      assert LLM.validate(value) == {:error, :invalid_llm_configuration}

      assert LLM.to_provider_settings_projection(value) ==
               {:error, :invalid_llm_configuration}
    end

    inspected = inspect(llm)
    assert inspected =~ "provider: :openai_compatible"

    for hidden <- ["BASE_URL", "MODEL", "API_KEY"] do
      refute inspected =~ hidden
    end
  end

  defp valid_document(overrides \\ %{}) do
    Map.merge(
      %{
        "provider" => "openai_compatible",
        "base_url_env" => "CLUSTER_MURMUR_LLM_BASE_URL",
        "model_env" => "CLUSTER_MURMUR_LLM_MODEL",
        "api_key_file_env" => "CLUSTER_MURMUR_LLM_API_KEY_FILE",
        "timeout" => "20s",
        "max_output_tokens" => 300
      },
      overrides
    )
  end
end
