defmodule ClusterMurmur.Observers.TargetCatalogTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observers.{Target, TargetCatalog}

  test "normalizes exact target maps into stable redacted order" do
    assert {:ok, %TargetCatalog{} = catalog} =
             TargetCatalog.parse([
               %{id: "example-target-b"},
               %{id: "example-target-a"}
             ])

    assert Enum.map(catalog.targets, & &1.id) == ["example-target-a", "example-target-b"]
    assert TargetCatalog.validate(catalog) == :ok
    assert inspect(catalog) == "#ClusterMurmur.Observers.TargetCatalog<...>"

    for target <- catalog.targets do
      assert inspect(target) == "#ClusterMurmur.Observers.Target<...>"
      refute inspect(target) =~ target.id
    end

    assert TargetCatalog.parse([]) == {:ok, %TargetCatalog{targets: []}}
  end

  test "rejects malformed, duplicate, improper, and excessive target lists" do
    too_many = Enum.map(1..257, &%{id: "example-target-#{&1}"})
    oversized_ids = Enum.map(1..5, &%{id: "target-#{&1}-" <> String.duplicate("x", 14_000)})

    for targets <- [
          nil,
          %{},
          [%{"id" => "example-target"}],
          [%{id: "example-target", private: true}],
          [%{id: "bad target"}],
          [%{id: "example-target"}, %{id: "example-target"}],
          [%{id: "example-target"} | :improper],
          too_many,
          oversized_ids
        ] do
      assert TargetCatalog.parse(targets) == {:error, :invalid_observer_targets}
    end
  end

  test "accepts the fixed maximum target count" do
    targets = Enum.map(1..256, &%{id: "example-target-#{&1}"})

    assert {:ok, %TargetCatalog{targets: normalized}} = TargetCatalog.parse(targets)
    assert length(normalized) == 256
  end

  test "rejects forged targets and catalogs during revalidation" do
    valid = %TargetCatalog{targets: [%Target{id: "example-target"}]}

    for catalog <- [
          nil,
          %{valid | targets: [%{__struct__: Target}]},
          %{valid | targets: [%Target{id: "bad target"}]},
          %{valid | targets: [%Target{id: "b"}, %Target{id: "a"}]},
          Map.put(valid, :private, true)
        ] do
      assert TargetCatalog.validate(catalog) == {:error, :invalid_observer_targets}
    end
  end
end
