defmodule ClusterMurmur.Config.ExternalIngestionTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Config.ExternalIngestion.Source

  test "defaults to a disabled empty source allowlist" do
    assert ExternalIngestion.default() == %ExternalIngestion{sources: %{}}
    assert ExternalIngestion.validate(ExternalIngestion.default()) == :ok
  end

  test "parses exact source-scoped allowlists" do
    assert {:ok,
            %ExternalIngestion{
              sources: %{
                "alert-adapter" => %Source{} = source
              }
            }} = ExternalIngestion.parse(document())

    assert source.event_types == MapSet.new(["component.failed", "component.recovered"])
    assert source.groups == MapSet.new(["operations"])
    assert source.subjects == MapSet.new(["example-component"])
    assert source.fact_keys == MapSet.new(["state", "summary"])
    assert source.label_keys == MapSet.new(["site"])
  end

  test "rejects unknown fields, duplicate values, and empty required allowlists" do
    invalid = [
      Map.put(document(), "private", true),
      put_in(document(), ["sources", "alert-adapter", "private"], []),
      put_in(document(), ["sources", "alert-adapter", "event_types"], []),
      put_in(document(), ["sources", "alert-adapter", "groups"], ["operations", "operations"]),
      put_in(document(), ["sources", "alert-adapter", "subjects"], "example-component"),
      %{"sources" => %{"bad source" => source_document()}}
    ]

    for value <- invalid do
      result = ExternalIngestion.parse(value)
      assert result == {:error, :invalid_external_ingestion_configuration}
      refute inspect(result) =~ "private"
    end
  end

  test "bounds source and allowlist counts" do
    too_many_sources =
      Map.new(1..33, fn index ->
        {"source-#{index}", source_document()}
      end)

    assert ExternalIngestion.parse(%{"sources" => too_many_sources}) ==
             {:error, :invalid_external_ingestion_configuration}

    too_many_types = Enum.map(1..257, &"event-#{&1}")

    assert document()
           |> put_in(["sources", "alert-adapter", "event_types"], too_many_types)
           |> ExternalIngestion.parse() ==
             {:error, :invalid_external_ingestion_configuration}
  end

  test "revalidation rejects forged shapes and inspection hides allowlists" do
    assert {:ok, configuration} = ExternalIngestion.parse(document())

    invalid = [
      nil,
      Map.put(configuration, :private, true),
      put_in(configuration.sources["alert-adapter"].event_types, ["private"]),
      put_in(configuration.sources["alert-adapter"].groups, MapSet.new())
    ]

    for value <- invalid do
      assert ExternalIngestion.validate(value) ==
               {:error, :invalid_external_ingestion_configuration}
    end

    inspected = inspect(configuration)
    refute inspected =~ "alert-adapter"
    refute inspected =~ "component.failed"
  end

  defp document do
    %{"sources" => %{"alert-adapter" => source_document()}}
  end

  defp source_document do
    %{
      "event_types" => ["component.failed", "component.recovered"],
      "groups" => ["operations"],
      "subjects" => ["example-component"],
      "fact_keys" => ["state", "summary"],
      "label_keys" => ["site"]
    }
  end
end
