defmodule ClusterMurmur.Persistence.EventDispatchStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Events.Event

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchCandidate,
    EventDispatchReceipt,
    EventDispatchStore,
    EventStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEventDispatches, CreateEvents}

  @events_version 20_260_804_180_500
  @dispatches_version 20_260_808_150_000
  @enqueued_at ~U[2026-08-08 15:00:02.000000Z]

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

  test "enqueues only an exact committed event and restores identical retries" do
    event = event("event-a")

    assert EventDispatchStore.enqueue(event, @enqueued_at) == {:error, :event_not_found}
    assert {:ok, _record} = EventStore.insert(event)

    assert {:ok, %EventDispatchReceipt{} = first} =
             EventDispatchStore.enqueue(event, @enqueued_at)

    assert first.status == :pending
    assert {:ok, second} = EventDispatchStore.enqueue(event, @enqueued_at)
    assert second == first
    assert Repo.aggregate(EventDispatch, :count) == 1

    assert EventDispatchStore.enqueue(event, DateTime.add(@enqueued_at, 1, :second)) ==
             {:error, :dispatch_conflict}

    changed = %{event | type: "observation.recovered"}
    assert EventDispatchStore.enqueue(changed, @enqueued_at) == {:error, :event_conflict}

    refute inspect(first) =~ event.id
    refute inspect(first) =~ "2026"
  end

  test "restores a claim-free receipt without changing outbox state" do
    event = event("event-a")
    assert {:ok, _record} = EventStore.insert(event)
    assert EventDispatchStore.fetch_receipt(event) == {:error, :dispatch_not_found}
    assert {:ok, pending} = EventDispatchStore.enqueue(event, @enqueued_at)
    assert EventDispatchStore.fetch_receipt(event) == {:ok, pending}

    assert {:ok, [candidate]} = EventDispatchStore.list_available(@enqueued_at)
    assert {:ok, _claim} = EventDispatchStore.claim(candidate, @enqueued_at)
    assert {:ok, claimed} = EventDispatchStore.fetch_receipt(event)
    assert claimed.status == :claimed
    refute Map.has_key?(claimed, :claim_token)

    changed = %{event | type: "observation.recovered"}
    assert EventDispatchStore.fetch_receipt(changed) == {:error, :event_conflict}
  end

  test "lists available entries deterministically without claim material and caps at 100" do
    for number <- 0..100 do
      id = "event-#{String.pad_leading(Integer.to_string(number), 3, "0")}"
      current = event(id)
      assert {:ok, _record} = EventStore.insert(current)
      assert {:ok, _dispatch} = EventDispatchStore.enqueue(current, @enqueued_at)
    end

    assert {:ok, candidates} = EventDispatchStore.list_available(@enqueued_at)
    assert length(candidates) == 100
    assert hd(candidates).event_id == "event-000"
    assert List.last(candidates).event_id == "event-099"
    assert Enum.all?(candidates, &match?(%EventDispatchCandidate{}, &1))
    refute inspect(candidates) =~ "event-000"
    refute inspect(candidates) =~ "2026"
  end

  test "leases, reclaims, and completes one exact available dispatch" do
    event = event("event-a")
    assert {:ok, _record} = EventStore.insert(event)
    assert {:ok, _dispatch} = EventDispatchStore.enqueue(event, @enqueued_at)
    assert {:ok, [candidate]} = EventDispatchStore.list_available(@enqueued_at)

    claimed_at = DateTime.add(@enqueued_at, 1, :second)
    assert {:ok, first_claim} = EventDispatchStore.claim(candidate, claimed_at)
    assert {:ok, []} = EventDispatchStore.list_available(claimed_at)
    assert EventDispatchStore.claim(candidate, claimed_at) == {:error, :dispatch_conflict}

    assert {:ok, claimed_receipt} = EventDispatchStore.enqueue(event, @enqueued_at)
    assert claimed_receipt.status == :claimed
    refute Map.has_key?(claimed_receipt, :claim_token)
    refute Map.has_key?(claimed_receipt, :claim_started_at)
    refute Map.has_key?(claimed_receipt, :claim_expires_at)
    refute inspect(claimed_receipt) =~ first_claim.token

    refute inspect(first_claim) =~ event.id
    refute inspect(first_claim) =~ first_claim.token

    expires_at = DateTime.add(claimed_at, 60, :second)
    assert first_claim.expires_at == expires_at
    assert {:ok, [expired]} = EventDispatchStore.list_available(expires_at)
    assert {:ok, second_claim} = EventDispatchStore.claim(expired, expires_at)
    refute second_claim.token == first_claim.token

    assert EventDispatchStore.complete(first_claim, DateTime.add(claimed_at, 2, :second)) ==
             {:error, :dispatch_conflict}

    completed_at = DateTime.add(expires_at, 1, :second)
    assert {:ok, completed} = EventDispatchStore.complete(second_claim, completed_at)
    assert completed.status == :completed
    assert completed.completed_at == completed_at
    assert completed.claim_token == nil
    assert {:ok, []} = EventDispatchStore.list_available(completed_at)
  end

  test "omits future entries without poisoning earlier available work" do
    available = event("available")
    future = event("future")
    future_at = DateTime.add(@enqueued_at, 3_600, :second)

    for current <- [available, future] do
      assert {:ok, _record} = EventStore.insert(current)
    end

    assert {:ok, _receipt} = EventDispatchStore.enqueue(available, @enqueued_at)
    assert {:ok, _receipt} = EventDispatchStore.enqueue(future, future_at)

    assert {:ok, [candidate]} = EventDispatchStore.list_available(@enqueued_at)
    assert candidate.event_id == available.id

    assert {:ok, candidates} = EventDispatchStore.list_available(future_at)
    assert Enum.map(candidates, & &1.event_id) == [available.id, future.id]
  end

  test "rejects malformed and expired capabilities before mutation" do
    event = event("event-a")
    assert {:ok, _record} = EventStore.insert(event)
    assert {:ok, _dispatch} = EventDispatchStore.enqueue(event, @enqueued_at)
    assert {:ok, [candidate]} = EventDispatchStore.list_available(@enqueued_at)

    malformed_candidate = Map.put(candidate, :private, "private")

    assert EventDispatchStore.claim(malformed_candidate, @enqueued_at) ==
             {:error, :invalid_dispatch}

    assert {:ok, claim} = EventDispatchStore.claim(candidate, @enqueued_at)
    malformed_claim = %{claim | token: "invalid"}

    assert EventDispatchStore.complete(malformed_claim, DateTime.add(@enqueued_at, 1, :second)) ==
             {:error, :invalid_dispatch}

    assert EventDispatchStore.complete(claim, claim.expires_at) ==
             {:error, :invalid_dispatch}

    assert Repo.get!(EventDispatch, event.id).status == :claimed
  end

  test "classifies invalid inputs before unavailable storage" do
    Repo.put_dynamic_repo(:missing_event_dispatch_repo)

    assert EventDispatchStore.enqueue(%{event("event-a") | id: ""}, @enqueued_at) ==
             {:error, :invalid_event}

    invalid_time = %{~U[2026-08-08 15:00:02.000000Z] | hour: 24}

    assert EventDispatchStore.list_available(invalid_time) ==
             {:error, :invalid_datetime}

    assert EventDispatchStore.claim(
             %EventDispatchCandidate{
               event_id: "event-a",
               enqueued_at: @enqueued_at
             },
             invalid_time
           ) == {:error, :invalid_datetime}

    assert EventDispatchStore.claim(
             %EventDispatchCandidate{event_id: "event-a", enqueued_at: @enqueued_at},
             ~U[9999-12-31 23:59:30.000000Z]
           ) == {:error, :invalid_datetime}
  end

  defp event(id) do
    %Event{
      id: id,
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      previous: "healthy",
      current: "unhealthy",
      occurred_at: ~U[2026-08-08 15:00:00.000000Z],
      observed_at: ~U[2026-08-08 15:00:01.000000Z],
      dedupe_key: nil,
      correlation_key: nil,
      facts: %{},
      labels: %{}
    }
  end
end
