defmodule ClusterMurmur.Config.RoutingTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{LoadedDocument, Routing}

  test "validates the default route environment-variable name" do
    document = %{
      "routing" => %{
        "default" => %{"webhook_secret_file_env" => "CLUSTER_MURMUR_DISCORD_WEBHOOK_FILE"}
      }
    }

    assert Routing.parse_documents([loaded(document)]) ==
             {:ok,
              %Routing{
                webhook_secret_file_env: "CLUSTER_MURMUR_DISCORD_WEBHOOK_FILE"
              }}
  end

  test "requires exactly one default route" do
    assert Routing.parse_documents([]) == {:error, :missing_default_route}

    document = loaded(valid_document("WEBHOOK_FILE"))

    assert Routing.parse_documents([document, document]) ==
             {:error, :duplicate_default_route}

    invalid = loaded(%{})

    assert Routing.parse_documents([document, invalid]) ==
             {:error, :duplicate_default_route}

    assert Routing.parse_documents([invalid, document]) ==
             {:error, :duplicate_default_route}

    assert Routing.parse_documents([document, %{}]) ==
             {:error, :invalid_routing_document}
  end

  test "rejects unknown and missing routing fields" do
    invalid = [
      %{},
      %{"routing" => %{}},
      %{"routing" => %{"groups" => %{}}},
      %{"routing" => %{"default" => %{}}},
      %{
        "routing" => %{
          "default" => %{
            "webhook_secret_file_env" => "WEBHOOK_FILE",
            "url" => "https://example.invalid"
          }
        }
      },
      Map.put(valid_document("WEBHOOK_FILE"), "extra", true)
    ]

    for document <- invalid do
      assert Routing.parse_documents([loaded(document)]) == {:error, :invalid_routing_document}
    end
  end

  test "rejects secret values and non-portable environment-variable names" do
    invalid = [
      "",
      "1WEBHOOK_FILE",
      "WEBHOOK-FILE",
      "WEBHOOK FILE",
      "観測者",
      String.duplicate("A", 129),
      "https://example.invalid/webhook",
      <<255>>,
      nil
    ]

    for value <- invalid do
      assert Routing.parse_documents([loaded(valid_document(value))]) ==
               {:error, :invalid_routing_document}
    end
  end

  test "rejects malformed document collections and non-JSON terms" do
    assert Routing.parse_documents(nil) == {:error, :invalid_routing_document}
    assert Routing.parse_documents([%{}]) == {:error, :invalid_routing_document}

    assert Routing.parse_documents([loaded(URI.parse("https://example.invalid"))]) ==
             {:error, :invalid_routing_document}

    assert Routing.parse_documents([loaded(%{"routing" => [%{} | :tail]})]) ==
             {:error, :invalid_routing_document}
  end

  test "redacts the environment-variable name from inspection" do
    routing = %Routing{webhook_secret_file_env: "PRIVATE_WEBHOOK_FILE"}
    refute inspect(routing) =~ "PRIVATE_WEBHOOK_FILE"
  end

  defp valid_document(value) do
    %{"routing" => %{"default" => %{"webhook_secret_file_env" => value}}}
  end

  defp loaded(document),
    do: %LoadedDocument{path: "/config/example.invalid.yaml", document: document}
end
