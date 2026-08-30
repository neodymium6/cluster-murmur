defmodule ClusterMurmur.Ingestion.HTTPSettingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{BearerAuthentication, HTTPSettings}
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @token "abcdefghijklmnopqrstuvwxyzABCDEF123456"

  setup do
    test_root = PrivateTmpDir.create!("cluster-murmur-ingestion-settings-test")
    on_exit(fn -> File.rm_rf!(test_root) end)
    %{test_root: test_root}
  end

  test "keeps an empty source policy disabled without reading environment" do
    assert HTTPSettings.load(ExternalIngestion.default(), fn _name ->
             flunk("disabled ingestion must not read environment")
           end) == {:ok, :disabled}
  end

  test "loads a port and only the digest of a mounted Bearer token", %{test_root: root} do
    token_path = write(root, "ingestion-token", @token <> "\n")

    assert {:ok, %HTTPSettings{} = settings} =
             HTTPSettings.load(configuration(), environment(token_path, "18081"))

    assert settings.port == 18_081
    assert {:ok, expected_digest} = BearerAuthentication.digest(@token)
    assert settings.token_digest == expected_digest
    assert HTTPSettings.validate(settings) == :ok
    refute inspect(settings) =~ @token
    refute inspect(settings) =~ Base.encode16(expected_digest)
  end

  test "fails closed for missing, malformed, or non-secret enabled settings", %{
    test_root: root
  } do
    valid_path = write(root, "valid", @token)
    short_path = write(root, "short", "short-token")
    missing_path = Path.join(root, "missing")

    invalid = [
      environment(:missing, "18081"),
      environment(valid_path, :missing),
      environment(valid_path, "0"),
      environment(valid_path, "65536"),
      environment(valid_path, "18081 "),
      environment(short_path, "18081"),
      environment(missing_path, "18081")
    ]

    for reader <- invalid do
      assert HTTPSettings.load(configuration(), reader) ==
               {:error, :invalid_external_ingestion_http_settings}
    end
  end

  test "rejects invalid configuration and forged normalized settings" do
    assert HTTPSettings.load(nil, fn _name -> :error end) ==
             {:error, :invalid_external_ingestion_http_settings}

    valid = %HTTPSettings{port: 18_081, token_digest: :crypto.hash(:sha256, @token)}

    for candidate <- [
          nil,
          %{valid | port: 0},
          %{valid | token_digest: <<0>>},
          Map.put(valid, :private, true)
        ] do
      assert HTTPSettings.validate(candidate) ==
               {:error, :invalid_external_ingestion_http_settings}
    end
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

  defp environment(token_path, port) do
    fn
      "CLUSTER_MURMUR_INGESTION_PORT" -> environment_value(port)
      "CLUSTER_MURMUR_INGESTION_TOKEN_FILE" -> environment_value(token_path)
      _name -> :error
    end
  end

  defp environment_value(:missing), do: :error
  defp environment_value(value), do: {:ok, value}

  defp write(root, name, contents) do
    path = Path.join(root, name)
    File.write!(path, contents)
    Path.expand(path)
  end
end
