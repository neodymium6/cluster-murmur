defmodule ClusterMurmur.Persistence.ExternalEventCommitStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.ExternalIngestion
  alias ClusterMurmur.Ingestion.{EventEnvelope, EventProjector}

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchStore,
    EventRecord,
    EventStore,
    ExternalEventCommitStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEventDispatches, CreateEvents}

  @events_version 20_260_804_180_500
  @dispatches_version 20_260_808_150_000
  @accepted_at ~U[2026-08-30 15:00:01.000000Z]

  setup_all do
    migrations = [
      {@events_version, CreateEvents},
      {@dispatches_version, CreateEventDispatches}
    ]

    for {version, migration} <- migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(migrations) do
        Ecto.Migrator.down(Repo, version, migration,
          log: false,
          log_migrations_sql: false,
          log_migrator_sql: false
        )
      end
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM event_dispatches", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "commits one event and pending dispatch atomically" do
    assert {:ok, result} =
             ExternalEventCommitStore.commit(envelope(), configuration(), @accepted_at)

    refute result.duplicate?
    assert result.dispatch.status == :pending
    assert result.dispatch.enqueued_at == @accepted_at
    assert result.event.id == result.dispatch.event_id
    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
    refute inspect(result) =~ "retry-identity"
    refute inspect(result) =~ "bounded summary"
  end

  test "restores an exact retry without changing its first enqueue time" do
    assert {:ok, first} =
             ExternalEventCommitStore.commit(envelope(), configuration(), @accepted_at)

    later = DateTime.add(@accepted_at, 30, :second)
    assert {:ok, duplicate} = ExternalEventCommitStore.commit(envelope(), configuration(), later)

    assert duplicate.duplicate?
    assert duplicate.event == first.event
    assert duplicate.dispatch == first.dispatch
    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
  end

  test "restores a completed dispatch without producing another handoff" do
    assert {:ok, first} =
             ExternalEventCommitStore.commit(envelope(), configuration(), @accepted_at)

    assert {:ok, [candidate]} = EventDispatchStore.list_available(@accepted_at)
    claimed_at = DateTime.add(@accepted_at, 1, :second)
    assert {:ok, claim} = EventDispatchStore.claim(candidate, claimed_at)

    assert {:ok, _dispatch} =
             EventDispatchStore.complete(claim, DateTime.add(claimed_at, 1, :second))

    assert {:ok, duplicate} =
             ExternalEventCommitStore.commit(
               envelope(),
               configuration(),
               DateTime.add(@accepted_at, 3, :second)
             )

    assert duplicate.duplicate?
    assert duplicate.dispatch.status == :completed
    assert duplicate.dispatch.event_id == first.dispatch.event_id
    assert Repo.aggregate(EventDispatch, :count) == 1
  end

  test "rejects changed content under an existing source identity" do
    assert {:ok, first} =
             ExternalEventCommitStore.commit(envelope(), configuration(), @accepted_at)

    changed = %{envelope() | facts: %{"state" => "failed", "summary" => "changed"}}

    assert ExternalEventCommitStore.commit(changed, configuration(), @accepted_at) ==
             {:error, :external_event_conflict}

    assert Repo.get!(EventRecord, first.event.id) == first.event
    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
  end

  test "rejects a partial durable pair instead of repairing uncertain state" do
    assert {:ok, event} = EventProjector.project(envelope(), configuration())
    assert {:ok, _record} = EventStore.insert(event)

    assert ExternalEventCommitStore.commit(envelope(), configuration(), @accepted_at) ==
             {:error, :external_event_conflict}

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 0
  end

  test "classifies invalid input before persistence" do
    before_occurrence = DateTime.add(envelope().occurred_at, -1, :second)

    invalid = [
      {%{envelope() | subject: "other"}, configuration(), @accepted_at},
      {envelope(), ExternalIngestion.default(), @accepted_at},
      {envelope(), configuration(), before_occurrence},
      {envelope(), configuration(), nil}
    ]

    for {candidate, configuration, accepted_at} <- invalid do
      assert ExternalEventCommitStore.commit(candidate, configuration, accepted_at) ==
               {:error, :invalid_external_event_commit}
    end

    assert Repo.aggregate(EventRecord, :count) == 0
    assert Repo.aggregate(EventDispatch, :count) == 0
  end

  defp envelope do
    %EventEnvelope{
      idempotency_key: "retry-identity",
      type: "component.failed",
      source: "alert-adapter",
      subject: "example-component",
      group: "operations",
      severity: "warning",
      occurred_at: ~U[2026-08-30 15:00:00.000000Z],
      facts: %{"state" => "failed", "summary" => "bounded summary"},
      labels: %{"site" => "example-site"}
    }
  end

  defp configuration do
    {:ok, configuration} =
      ExternalIngestion.parse(%{
        "sources" => %{
          "alert-adapter" => %{
            "event_types" => ["component.failed", "component.recovered"],
            "groups" => ["operations"],
            "subjects" => ["example-component"],
            "fact_keys" => ["state", "summary"],
            "label_keys" => ["site"]
          }
        }
      })

    configuration
  end
end
