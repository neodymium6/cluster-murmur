defmodule ClusterMurmur.Personas.BindingValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Personas.{Binding, BindingValidator}

  test "accepts exact bounded runtime bindings" do
    assert BindingValidator.validate(binding_value([])) == :ok

    candidates = Enum.map(1..256, &%{persona: "persona-#{&1}", weight: &1 / 10})
    assert BindingValidator.validate(binding_value(candidates: candidates)) == :ok
  end

  test "rejects malformed binding identities and exact shape" do
    valid = binding_value([])

    for rejected <- [
          nil,
          %{},
          %{valid | id: "invalid id"},
          %{valid | group: "invalid group"},
          Map.delete(valid, :candidates),
          Map.put(valid, :unexpected_private_value, "private")
        ] do
      result = BindingValidator.validate(rejected)
      assert result == {:error, :invalid_binding}
      refute inspect(result) =~ "private"
    end
  end

  test "requires one to 256 exact candidates" do
    assert BindingValidator.validate(binding_value(candidates: [])) == {:error, :invalid_binding}

    overflow = Enum.map(1..257, &%{persona: "persona-#{&1}", weight: 1})

    assert BindingValidator.validate(binding_value(candidates: overflow)) ==
             {:error, :too_many_candidates}

    assert BindingValidator.validate(
             binding_value(candidates: [%{persona: "observer", weight: 1} | :tail])
           ) ==
             {:error, :invalid_binding}
  end

  test "rejects duplicate, malformed, and unbounded candidates" do
    valid = %{persona: "observer", weight: 1}

    for {candidates, expected} <- [
          {[valid, valid], :duplicate_binding_candidate},
          {[%{persona: "invalid id", weight: 1}], :invalid_binding},
          {[%{persona: "observer", weight: -1}], :invalid_binding},
          {[%{persona: "observer", weight: :infinity}], :invalid_binding},
          {[Map.put(valid, :unexpected_private_value, "private")], :invalid_binding},
          {[Map.delete(valid, :weight)], :invalid_binding}
        ] do
      assert BindingValidator.validate(binding_value(candidates: candidates)) ==
               {:error, expected}
    end
  end

  test "redacted binding inspection remains unchanged" do
    value =
      binding_value(
        id: "private-binding",
        group: "private-group",
        candidates: [%{persona: "private-persona", weight: 1}]
      )

    assert BindingValidator.validate(value) == :ok
    refute inspect(value) =~ "private"
  end

  defp binding_value(overrides) do
    struct!(
      Binding,
      Keyword.merge(
        [
          id: "operations-characters",
          group: "operations",
          candidates: [%{persona: "observer", weight: 1}]
        ],
        overrides
      )
    )
  end
end
