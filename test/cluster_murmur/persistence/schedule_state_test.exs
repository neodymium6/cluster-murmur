defmodule ClusterMurmur.Persistence.ScheduleStateTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.ScheduleState

  @next ~U[2026-08-10 00:00:00.000000Z]
  @token Base.url_encode64(<<0::256>>, padding: false)

  test "builds only bounded ordered state and exact claim triples" do
    assert changeset(%{trigger_id: "daily-summary", next_run_at: @next}).valid?

    assert changeset(%{
             trigger_id: "daily-summary",
             next_run_at: @next,
             last_run_at: DateTime.add(@next, -1, :minute),
             claim_token: @token,
             claim_started_at: DateTime.add(@next, 1, :second),
             claim_expires_at: DateTime.add(@next, 61, :second)
           }).valid?

    for attributes <- [
          %{trigger_id: "bad id", next_run_at: @next},
          %{trigger_id: "daily-summary", next_run_at: nil},
          %{trigger_id: "daily-summary", next_run_at: @next, last_run_at: @next},
          %{trigger_id: "daily-summary", next_run_at: @next, claim_token: @token},
          %{
            trigger_id: "daily-summary",
            next_run_at: @next,
            last_run_at: %{@next | month: 13}
          },
          %{
            trigger_id: "daily-summary",
            next_run_at: @next,
            claim_token: @token,
            claim_started_at: %{@next | month: 13},
            claim_expires_at: DateTime.add(@next, 60, :second)
          },
          %{
            trigger_id: "daily-summary",
            next_run_at: @next,
            claim_token: String.duplicate("A", 1_000_000)
          },
          %{trigger_id: "daily-summary", next_run_at: @next, private: "private"}
        ] do
      refute changeset(attributes).valid?
    end
  end

  test "revalidates every complete field on non-pristine records" do
    invalid_states = [
      %ScheduleState{trigger_id: "bad id", next_run_at: @next},
      %ScheduleState{trigger_id: "daily-summary", next_run_at: %{@next | month: 13}},
      Map.put(%ScheduleState{}, :private, "private")
    ]

    for state <- invalid_states do
      refute ScheduleState.changeset(state, %{claim_token: nil}).valid?
    end
  end

  test "rejects forged Ecto metadata without raising" do
    for metadata <- [
          nil,
          %Ecto.Schema.Metadata{state: :built, source: "events", schema: ScheduleState},
          %Ecto.Schema.Metadata{state: :deleted, source: "schedule_states", schema: ScheduleState}
        ] do
      state = %ScheduleState{__meta__: metadata}
      refute ScheduleState.changeset(state, %{}).valid?
      refute ScheduleState.changeset(state, :invalid).valid?
    end

    loaded = Ecto.put_meta(%ScheduleState{}, state: :loaded)

    assert ScheduleState.changeset(loaded, %{trigger_id: "daily-summary", next_run_at: @next}).valid?
  end

  test "rejects attribute maps above the closed field bound" do
    attributes =
      1..10_000
      |> Map.new(fn key -> {key, key} end)
      |> Map.merge(%{trigger_id: "daily-summary", next_run_at: @next})

    refute changeset(attributes).valid?
  end

  defp changeset(attributes), do: ScheduleState.changeset(%ScheduleState{}, attributes)
end
