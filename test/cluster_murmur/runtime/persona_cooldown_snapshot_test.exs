defmodule ClusterMurmur.Runtime.PersonaCooldownSnapshotTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.PersonaCooldownRecord
  alias ClusterMurmur.Runtime.PersonaCooldownSnapshot
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @spoken_at ~U[2026-08-11 06:00:00.000000Z]
  @cooldown_until ~U[2026-08-11 06:01:00.000000Z]

  defmodule Store do
    def fetch(persona_id) do
      trace_key = {ClusterMurmur.Runtime.PersonaCooldownSnapshotTest, :fetches}
      Process.put(trace_key, Process.get(trace_key, []) ++ [persona_id])

      Process.get(
        {ClusterMurmur.Runtime.PersonaCooldownSnapshotTest, persona_id},
        {:ok, nil}
      )
    end
  end

  test "restores configured cooldowns once in stable persona order" do
    configuration = configuration_with_second_persona()
    caretaker = cooldown("caretaker")
    observer = cooldown("observer")
    Process.put({__MODULE__, "caretaker"}, {:ok, caretaker})
    Process.put({__MODULE__, "observer"}, {:ok, observer})

    assert PersonaCooldownSnapshot.load(configuration, Store) ==
             {:ok, %{"caretaker" => caretaker, "observer" => observer}}

    assert Process.get({__MODULE__, :fetches}) == ["caretaker", "observer"]
    assert PersonaCooldownSnapshot.validate(%{"caretaker" => caretaker}, configuration) == :ok
  end

  test "omits configured personas without durable cooldowns" do
    configuration = RuntimeFixture.configuration()

    assert PersonaCooldownSnapshot.load(configuration, Store) == {:ok, %{}}
    assert Process.get({__MODULE__, :fetches}) == ["caretaker"]
  end

  test "fails closed on storage errors and malformed or mismatched records" do
    configuration = RuntimeFixture.configuration()

    for response <- [
          {:error, :storage_unavailable},
          {:ok, %{private: true}},
          {:ok, cooldown("observer")},
          {:ok, %{cooldown("caretaker") | __meta__: %Ecto.Schema.Metadata{state: :built}}}
        ] do
      Process.put({__MODULE__, "caretaker"}, response)

      assert PersonaCooldownSnapshot.load(configuration, Store) ==
               {:error, :persona_cooldown_snapshot_failed}
    end
  end

  test "validates every dependency before the first store read" do
    valid = RuntimeFixture.configuration()

    for {configuration, store} <- [
          {nil, Store},
          {%{valid | version: 1.0}, Store},
          {Map.put(valid, :private, true), Store},
          {valid, String}
        ] do
      assert PersonaCooldownSnapshot.load(configuration, store) ==
               {:error, :invalid_persona_cooldown_snapshot}
    end

    assert Process.get({__MODULE__, :fetches}, []) == []

    assert PersonaCooldownSnapshot.validate(%{"unknown" => cooldown("unknown")}, valid) ==
             {:error, :invalid_persona_cooldown_snapshot}
  end

  defp configuration_with_second_persona do
    configuration = RuntimeFixture.configuration()
    caretaker = configuration.personas.personas["caretaker"]
    observer = %{caretaker | id: "observer", display_name: "Observer"}

    %{
      configuration
      | personas: %{
          configuration.personas
          | personas: Map.put(configuration.personas.personas, observer.id, observer)
        }
    }
  end

  defp cooldown(persona_id) do
    %PersonaCooldownRecord{
      persona_id: persona_id,
      last_spoken_at: @spoken_at,
      cooldown_until: @cooldown_until
    }
    |> Ecto.put_meta(state: :loaded)
  end
end
