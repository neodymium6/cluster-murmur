defmodule ClusterMurmur.Config.EventGroupsTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{DocumentDecoder, EventGroups, LoadedDocument}

  test "validates and combines bounded event-group documents" do
    assert {:ok, first} =
             decode("""
             event_groups:
               operations:
                 reply_probability: 0.25
               recovery:
                 reply_probability: 0
             """)

    assert {:ok, second} =
             decode("""
             event_groups:
               user:
                 reply_probability: 1
             """)

    assert EventGroups.parse_documents([loaded(first), loaded(second)]) ==
             {:ok,
              %EventGroups{
                groups: %{
                  "operations" => %{id: "operations", reply_probability: 0.25},
                  "recovery" => %{id: "recovery", reply_probability: 0},
                  "user" => %{id: "user", reply_probability: 1}
                }
              }}
  end

  test "accepts an empty category and empty event-group mappings" do
    assert EventGroups.parse_documents([]) == {:ok, %EventGroups{groups: %{}}}

    assert EventGroups.parse_documents([loaded(%{"event_groups" => %{}})]) ==
             {:ok, %EventGroups{groups: %{}}}
  end

  test "rejects structurally invalid documents without returning their values" do
    invalid_documents = [
      %{},
      %{"event_groups" => [], "private" => "value"},
      %{"event_groups" => %{"operations" => %{}}},
      %{"event_groups" => %{"operations" => %{"reply_probability" => 0.5, "extra" => true}}},
      %{"event_groups" => %{"operations" => %{"reply_probability" => "private"}}},
      %{"event_groups" => %{"operations" => %{"reply_probability" => -0.1}}},
      %{"event_groups" => %{"operations" => %{"reply_probability" => 1.1}}},
      %{"event_groups" => %{"invalid id" => %{"reply_probability" => 0.5}}}
    ]

    for document <- invalid_documents do
      result = EventGroups.parse_documents([loaded(document)])

      assert result == {:error, :invalid_event_group_document}
      refute inspect(result) =~ "private"
    end
  end

  test "applies the portable ID rule after structural validation" do
    document = %{
      "event_groups" => %{
        "operations\n" => %{"reply_probability" => 0.5}
      }
    }

    assert EventGroups.parse_documents([loaded(document)]) ==
             {:error, :invalid_event_group_document}
  end

  test "rejects duplicate IDs across files" do
    first = loaded(%{"event_groups" => %{"operations" => %{"reply_probability" => 0.25}}})
    second = loaded(%{"event_groups" => %{"operations" => %{"reply_probability" => 0.75}}})

    assert EventGroups.parse_documents([first, second]) ==
             {:error, :duplicate_event_group}
  end

  test "bounds the aggregate group count across files" do
    allowed =
      Map.new(1..256, fn index ->
        {"group-#{index}", %{"reply_probability" => 0.5}}
      end)

    assert {:ok, %EventGroups{groups: groups}} =
             EventGroups.parse_documents([loaded(%{"event_groups" => allowed})])

    assert map_size(groups) == 256

    overflow = loaded(%{"event_groups" => %{"group-257" => %{"reply_probability" => 0.5}}})

    assert EventGroups.parse_documents([loaded(%{"event_groups" => allowed}), overflow]) ==
             {:error, :too_many_event_groups}
  end

  test "rejects malformed document collections" do
    assert EventGroups.parse_documents(nil) == {:error, :invalid_event_group_document}
    assert EventGroups.parse_documents([%{}]) == {:error, :invalid_event_group_document}

    assert EventGroups.parse_documents([loaded(%{"event_groups" => %{}}) | :tail]) ==
             {:error, :invalid_event_group_document}
  end

  test "omits IDs and probabilities from inspection" do
    set = %EventGroups{
      groups: %{"private-group" => %{id: "private-group", reply_probability: 0.75}}
    }

    inspected = inspect(set)

    refute inspected =~ "private-group"
    refute inspected =~ "0.75"
  end

  defp decode(yaml), do: DocumentDecoder.decode(yaml)

  defp loaded(document) do
    %LoadedDocument{path: "/config/example.invalid.yaml", document: document}
  end
end
