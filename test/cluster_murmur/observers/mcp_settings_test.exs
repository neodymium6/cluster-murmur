defmodule ClusterMurmur.Observers.MCPSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.MCPSettings
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    test_root = PrivateTmpDir.create!("cluster-murmur-mcp-settings-test")
    token_path = Path.join(test_root, "token")
    File.write!(token_path, "clearly-fake-observer-token\n")
    on_exit(fn -> File.rm_rf!(test_root) end)
    %{token_path: token_path}
  end

  test "loads a redacted HTTPS endpoint and mounted token", context do
    assert {:ok, %MCPSettings{} = settings} = MCPSettings.load(environment(context.token_path))

    assert settings.endpoint == "https://observer.example.invalid/mcp"
    assert settings.bearer_token == "clearly-fake-observer-token"
    assert MCPSettings.validate(settings) == :ok

    inspected = inspect(settings)
    refute inspected =~ settings.endpoint
    refute inspected =~ settings.bearer_token
  end

  test "allows only loopback HTTP sidecars", context do
    for endpoint <- [
          "http://localhost:3000/mcp",
          "http://127.0.0.1:3000/mcp",
          "http://[::1]:3000/mcp"
        ] do
      assert {:ok, settings} =
               MCPSettings.load(environment(context.token_path, endpoint: endpoint))

      assert settings.endpoint == endpoint
    end

    assert MCPSettings.load(
             environment(context.token_path, endpoint: "http://observer.example.invalid/mcp")
           ) == {:error, :invalid_mcp_endpoint}
  end

  test "rejects endpoints outside the fixed MCP boundary", context do
    invalid = [
      "observer.example.invalid/mcp",
      "ftp://observer.example.invalid/mcp",
      "https://user@observer.example.invalid/mcp",
      "https://observer.example.invalid/other",
      "https://observer.example.invalid/mcp?private=true",
      "https://observer.example.invalid/mcp#fragment",
      "https://observer.example.invalid:0/mcp",
      "https://observer.example.invalid/%ZZ",
      <<"https://observer.example.invalid/mcp", 255>>
    ]

    for endpoint <- invalid do
      assert MCPSettings.load(environment(context.token_path, endpoint: endpoint)) ==
               {:error, :invalid_mcp_endpoint}
    end
  end

  test "distinguishes missing and malformed endpoint values", context do
    assert MCPSettings.load(environment(context.token_path, endpoint: :missing)) ==
             {:error, :missing_mcp_endpoint}

    for endpoint <- [nil, "  ", String.duplicate("a", 2_049)] do
      assert MCPSettings.load(environment(context.token_path, endpoint: endpoint)) ==
               {:error, :invalid_mcp_endpoint}
    end
  end

  test "loads the bearer token only through the mounted-secret boundary", context do
    assert MCPSettings.load(environment(context.token_path, token_path: :missing)) ==
             {:error, {:bearer_token, :missing_secret_file_path}}

    empty_path = Path.join(Path.dirname(context.token_path), "empty")
    File.write!(empty_path, "\n")

    assert MCPSettings.load(environment(empty_path)) ==
             {:error, {:bearer_token, :empty_secret}}
  end

  test "rejects malformed values and environment readers without leaking them" do
    valid = %MCPSettings{
      endpoint: "https://observer.example.invalid/mcp",
      bearer_token: "clearly-fake-observer-token"
    }

    for settings <- [
          %{valid | endpoint: "https://observer.example.invalid/other"},
          %{valid | bearer_token: "private\nvalue"},
          Map.put(valid, :private, true),
          nil
        ] do
      assert MCPSettings.validate(settings) == {:error, :invalid_mcp_settings}
    end

    assert MCPSettings.load(fn _name -> raise "private diagnostic" end) ==
             {:error, :invalid_mcp_settings}
  end

  defp environment(token_path, overrides \\ []) do
    endpoint = Keyword.get(overrides, :endpoint, "https://observer.example.invalid/mcp")
    token_path = Keyword.get(overrides, :token_path, token_path)

    fn
      "CLUSTER_MURMUR_OBSERVER_MCP_URL" -> environment_value(endpoint)
      "CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE" -> environment_value(token_path)
      _name -> :error
    end
  end

  defp environment_value(:missing), do: :error
  defp environment_value(value), do: {:ok, value}
end
