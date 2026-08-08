defmodule ClusterMurmur.Observers.PollerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.Observations.{DebouncePolicy, IngestionPlanner, Observation}
  alias ClusterMurmur.Observers.{Client, Poller}
  alias ClusterMurmur.Observers.Poller.Result

  defmodule FakeClient do
    def list_targets(:process_dictionary) do
      record({:observer, :list_targets})
      Process.get({__MODULE__, :targets}, {:ok, []})
    end

    def observe_target(:process_dictionary, id) do
      record({:observer, :observe_target, id})

      Process.get({__MODULE__, :observations}, %{})
      |> Map.get(id, {:error, :invalid_response})
    end

    defp record(call) do
      Process.put({__MODULE__, :calls}, calls() ++ [call])
    end

    defp calls, do: Process.get({__MODULE__, :calls}, [])
  end

  defmodule FakeIngestionStore do
    def ingest(observation, policy) do
      calls = Process.get({__MODULE__, :calls}, [])
      Process.put({__MODULE__, :calls}, calls ++ [observation.subject])

      case Map.fetch(Process.get({__MODULE__, :plans}, %{}), observation.subject) do
        {:ok, plan} ->
          {:ok, plan}

        :error ->
          if observation.subject in Process.get({__MODULE__, :failures}, []) do
            {:error, :private_storage_diagnostic}
          else
            ClusterMurmur.Observations.IngestionPlanner.plan(nil, observation, policy)
          end
      end
    end
  end

  setup do
    Process.put({FakeClient, :calls}, [])
    Process.put({FakeClient, :targets}, {:ok, []})
    Process.put({FakeClient, :observations}, %{})
    Process.put({FakeIngestionStore, :calls}, [])
    Process.put({FakeIngestionStore, :failures}, [])
    Process.put({FakeIngestionStore, :plans}, %{})
    :ok
  end

  test "polls a normalized catalog once in stable order and returns committed events" do
    Process.put(
      {FakeClient, :targets},
      {:ok, [%{id: "example-target-b"}, %{id: "example-target-a"}]}
    )

    Process.put(
      {FakeClient, :observations},
      %{
        "example-target-a" => {:ok, observation("example-target-a", 0)},
        "example-target-b" => {:ok, observation("example-target-b", 1)}
      }
    )

    state_tracking = %StateTracking{failures_required: 1, successes_required: 1}

    assert {:ok, %Result{} = result} =
             Poller.poll_once(client(), state_tracking, FakeIngestionStore)

    assert result.target_count == 2
    assert result.ingested_count == 2
    assert result.event_count == 2
    assert result.failure_count == 0
    assert Enum.map(result.events, & &1.subject) == ["example-target-a", "example-target-b"]
    assert result.failures == []
    assert Poller.validate_result(result) == :ok

    assert Process.get({FakeClient, :calls}) == [
             {:observer, :list_targets},
             {:observer, :observe_target, "example-target-a"},
             {:observer, :observe_target, "example-target-b"}
           ]

    assert Process.get({FakeIngestionStore, :calls}) == [
             "example-target-a",
             "example-target-b"
           ]
  end

  test "continues bounded polling with only stable partial-failure classes" do
    Process.put(
      {FakeClient, :targets},
      {:ok,
       [
         %{id: "example-target-a"},
         %{id: "example-target-b"},
         %{id: "example-target-c"}
       ]}
    )

    Process.put(
      {FakeClient, :observations},
      %{
        "example-target-a" => {:error, :timeout},
        "example-target-b" => {:ok, observation("wrong-target", 1)},
        "example-target-c" => {:ok, observation("example-target-c", 2)}
      }
    )

    Process.put({FakeIngestionStore, :failures}, ["example-target-c"])

    assert {:ok, result} =
             Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore)

    assert result.target_count == 3
    assert result.ingested_count == 0
    assert result.event_count == 0
    assert result.failure_count == 3
    assert result.events == []

    assert result.failures == [
             {:observer, :timeout},
             {:observer, :invalid_response},
             :ingestion_failed
           ]

    refute inspect(result) =~ "example-target"
    refute inspect(result) =~ "private"
  end

  test "validates configuration and the whole catalog before observing a target" do
    Process.put(
      {FakeClient, :targets},
      {:ok, [%{id: "duplicate"}, %{id: "duplicate"}]}
    )

    assert Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore) ==
             {:error, :invalid_observer_targets}

    assert Process.get({FakeClient, :calls}) == [{:observer, :list_targets}]

    Process.put({FakeClient, :calls}, [])

    assert Poller.poll_once(client(), nil, FakeIngestionStore) == {:error, :invalid_poll}
    assert Process.get({FakeClient, :calls}) == []
  end

  test "preserves only stable list failures and catches observer exceptions" do
    Process.put({FakeClient, :targets}, {:error, :unavailable})

    assert Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore) ==
             {:error, {:observer, :unavailable}}

    Process.put({FakeClient, :targets}, {:error, {:private, "diagnostic"}})

    assert Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore) ==
             {:error, {:observer, :invalid_response}}

    assert Poller.poll_once(
             %Client{adapter: String, context: nil},
             StateTracking.default(),
             FakeIngestionStore
           ) ==
             {:error, :invalid_poll}
  end

  test "rejects ingestion plans that are not correlated with the accepted observation" do
    accepted = observation("example-target", 0)
    unrelated = observation("unrelated-target", 1)
    policy = %DebouncePolicy{healthy_threshold: 1, unhealthy_threshold: 1}
    state_tracking = %StateTracking{failures_required: 1, successes_required: 1}

    Process.put({FakeClient, :targets}, {:ok, [%{id: "example-target"}]})
    Process.put({FakeClient, :observations}, %{"example-target" => {:ok, accepted}})

    assert {:ok, unrelated_plan} = IngestionPlanner.plan(nil, unrelated, policy)
    Process.put({FakeIngestionStore, :plans}, %{"example-target" => unrelated_plan})

    assert {:ok, result} = Poller.poll_once(client(), state_tracking, FakeIngestionStore)
    assert result.ingested_count == 0
    assert result.failures == [:ingestion_failed]

    assert {:ok, accepted_plan} = IngestionPlanner.plan(nil, accepted, policy)

    Process.put(
      {FakeIngestionStore, :plans},
      %{"example-target" => %{accepted_plan | event: unrelated_plan.event}}
    )

    assert {:ok, result} = Poller.poll_once(client(), state_tracking, FakeIngestionStore)
    assert result.ingested_count == 0
    assert result.failures == [:ingestion_failed]

    Process.put(
      {FakeIngestionStore, :plans},
      %{"example-target" => %{accepted_plan | event: nil}}
    )

    assert {:ok, result} = Poller.poll_once(client(), state_tracking, FakeIngestionStore)
    assert result.ingested_count == 0
    assert result.failures == [:ingestion_failed]

    pending_policy = %DebouncePolicy{healthy_threshold: 2, unhealthy_threshold: 2}
    assert {:ok, pending_plan} = IngestionPlanner.plan(nil, accepted, pending_policy)

    Process.put(
      {FakeIngestionStore, :plans},
      %{
        "example-target" => %{
          pending_plan
          | entity_state: %{pending_plan.entity_state | consecutive_count: 2}
        }
      }
    )

    assert {:ok, result} =
             Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore)

    assert result.ingested_count == 0
    assert result.failures == [:ingestion_failed]

    Process.put(
      {FakeIngestionStore, :plans},
      %{
        "example-target" => %{
          pending_plan
          | entity_state: %{pending_plan.entity_state | facts: %{"sample" => 0.0}}
        }
      }
    )

    assert {:ok, result} =
             Poller.poll_once(client(), StateTracking.default(), FakeIngestionStore)

    assert result.ingested_count == 0
    assert result.failures == [:ingestion_failed]
  end

  test "rejects forged result values with bounded collection validation" do
    valid = %Result{
      target_count: 0,
      ingested_count: 0,
      event_count: 0,
      failure_count: 0,
      events: [],
      failures: []
    }

    for result <- [
          nil,
          %{valid | target_count: 1},
          %{valid | failures: [:private_failure]},
          %{valid | events: [nil], event_count: 1},
          %{
            valid
            | target_count: 256,
              failure_count: 256,
              failures: List.duplicate(:ingestion_failed, 257)
          },
          %{valid | target_count: 1, failure_count: 1, failures: [:ingestion_failed | :tail]},
          Map.put(valid, :private, true)
        ] do
      assert Poller.validate_result(result) == {:error, :invalid_poll}
    end

    assert inspect(valid) ==
             "#ClusterMurmur.Observers.Poller.Result<target_count: 0, ingested_count: 0, event_count: 0, failure_count: 0, ...>"
  end

  defp observation(subject, offset) do
    %Observation{
      source: "example-observer",
      subject: subject,
      state: :unhealthy,
      observed_at: DateTime.add(~U[2026-08-06 17:00:00.000000Z], offset, :second),
      facts: %{"sample" => offset},
      labels: %{"category" => "monitoring"}
    }
  end

  defp client do
    {:ok, client} = Client.new(FakeClient, :process_dictionary)
    client
  end
end
