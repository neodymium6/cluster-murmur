defmodule ClusterMurmur.Config.BindingsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Bindings, LoadedDocument}
  alias ClusterMurmur.Personas.Binding

  test "validates, normalizes, and combines binding documents" do
    first =
      loaded(%{
        "bindings" => [
          binding("monitoring", "operations", [{"observer", 1.0}, {"caretaker", 0.4}])
        ]
      })

    second = loaded(%{"bindings" => [binding("recovery", "recovery", [{"caretaker", 1}])]})

    assert Bindings.parse_documents([first, second]) ==
             {:ok,
              %Bindings{
                bindings: %{
                  "monitoring" => %Binding{
                    id: "monitoring",
                    group: "operations",
                    candidates: [
                      %{persona: "caretaker", weight: 0.4},
                      %{persona: "observer", weight: 1.0}
                    ]
                  },
                  "recovery" => %Binding{
                    id: "recovery",
                    group: "recovery",
                    candidates: [%{persona: "caretaker", weight: 1}]
                  }
                }
              }}
  end

  test "accepts an empty category and empty binding lists" do
    assert Bindings.parse_documents([]) == {:ok, %Bindings{bindings: %{}}}

    assert Bindings.parse_documents([loaded(%{"bindings" => []})]) ==
             {:ok, %Bindings{bindings: %{}}}
  end

  test "rejects closed-schema violations" do
    valid = binding("monitoring", "operations", [{"observer", 1}])

    invalid = [
      %{},
      %{"bindings" => %{}},
      %{"bindings" => [Map.put(valid, "extra", true)]},
      %{"bindings" => [Map.delete(valid, "match")]},
      %{"bindings" => [put_in(valid, ["match", "extra"], true)]},
      %{"bindings" => [Map.put(valid, "candidates", [])]},
      %{"bindings" => [put_in(valid, ["candidates", Access.at(0), "weight"], -1)]},
      %{"bindings" => [put_in(valid, ["candidates", Access.at(0), "extra"], true)]}
    ]

    for document <- invalid do
      assert Bindings.parse_documents([loaded(document)]) == {:error, :invalid_binding_document}
    end
  end

  test "applies portable ID rules" do
    for invalid <- [
          binding("invalid id", "operations", [{"observer", 1}]),
          binding("monitoring", "invalid id", [{"observer", 1}]),
          binding("monitoring", "operations", [{"invalid id", 1}])
        ] do
      assert Bindings.parse_documents([loaded(%{"bindings" => [invalid]})]) ==
               {:error, :invalid_binding_document}
    end
  end

  test "rejects duplicate binding and candidate IDs" do
    first = loaded(%{"bindings" => [binding("monitoring", "operations", [{"observer", 1}])]})
    second = loaded(%{"bindings" => [binding("monitoring", "recovery", [{"caretaker", 1}])]})
    assert Bindings.parse_documents([first, second]) == {:error, :duplicate_binding}

    duplicated = binding("monitoring", "operations", [{"observer", 1}, {"observer", 0.5}])

    assert Bindings.parse_documents([loaded(%{"bindings" => [duplicated]})]) ==
             {:error, :duplicate_binding_candidate}
  end

  test "bounds bindings and candidates" do
    bindings = Enum.map(1..256, &binding("binding-#{&1}", "operations", [{"observer", 1}]))

    assert {:ok, %Bindings{bindings: result}} =
             Bindings.parse_documents([loaded(%{"bindings" => bindings})])

    assert map_size(result) == 256

    overflow = loaded(%{"bindings" => [binding("binding-257", "operations", [{"observer", 1}])]})

    assert Bindings.parse_documents([loaded(%{"bindings" => bindings}), overflow]) ==
             {:error, :too_many_bindings}

    candidates = Enum.map(1..257, &{"persona-#{&1}", 1})

    assert Bindings.parse_documents([
             loaded(%{"bindings" => [binding("large", "operations", candidates)]})
           ]) ==
             {:error, :invalid_binding_document}
  end

  test "rejects malformed document collections and non-JSON terms" do
    assert Bindings.parse_documents(nil) == {:error, :invalid_binding_document}
    assert Bindings.parse_documents([%{}]) == {:error, :invalid_binding_document}

    assert Bindings.parse_documents([loaded(URI.parse("https://example.invalid"))]) ==
             {:error, :invalid_binding_document}

    assert Bindings.parse_documents([loaded(%{"bindings" => [%{} | :tail]})]) ==
             {:error, :invalid_binding_document}
  end

  test "redacts binding configuration from inspection" do
    binding = %Binding{
      id: "private-binding",
      group: "private-group",
      candidates: [%{persona: "private-persona", weight: 1}]
    }

    set = %Bindings{bindings: %{"private-binding" => binding}}

    for inspected <- [inspect(binding), inspect(set)] do
      refute inspected =~ "private"
      refute inspected =~ "weight"
    end
  end

  defp binding(id, group, candidates) do
    %{
      "id" => id,
      "match" => %{"group" => group},
      "candidates" =>
        Enum.map(candidates, fn {persona, weight} ->
          %{"persona" => persona, "weight" => weight}
        end)
    }
  end

  defp loaded(document),
    do: %LoadedDocument{path: "/config/example.invalid.yaml", document: document}
end
