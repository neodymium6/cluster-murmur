defmodule ClusterMurmur.Runtime.RecoveryTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.Recovery
  alias ClusterMurmur.Runtime.Recovery.{Result, Stores}

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    PublicationAttemptRecord,
    TriggerExecution
  }

  @cutoff ~U[2026-08-07 01:00:00.000000Z]
  @recovered_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule Executions do
    alias ClusterMurmur.Runtime.RecoveryTest

    def list_started_before(_cutoff), do: load(:executions)
    def fail_abandoned(value, _cutoff), do: mutate({:execution, value.trigger_id})

    defp load(kind) do
      record({:load, kind})
      {:ok, Process.get({RecoveryTest, kind}, [])}
    end

    defp mutate(entry) do
      record(entry)
      response(entry)
    end

    defp response(entry),
      do: Map.get(Process.get({RecoveryTest, :responses}, %{}), entry, {:ok, :terminal})

    defp record(entry), do: Process.put({RecoveryTest, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({RecoveryTest, :trace}, [])
  end

  defmodule Conversations do
    alias ClusterMurmur.Runtime.RecoveryTest

    def list_active_before(_cutoff), do: load(:conversations)
    def fail(value, _recovered_at), do: mutate({:conversation, value.id})

    defp load(kind) do
      record({:load, kind})
      {:ok, Process.get({RecoveryTest, kind}, [])}
    end

    defp mutate(entry) do
      record(entry)
      Map.get(Process.get({RecoveryTest, :responses}, %{}), entry, {:ok, :terminal})
    end

    defp record(entry), do: Process.put({RecoveryTest, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({RecoveryTest, :trace}, [])
  end

  defmodule Publications do
    alias ClusterMurmur.Runtime.RecoveryTest

    def list_open_before(_cutoff), do: load(:publications)
    def mark_ambiguous(value, _recovered_at), do: mutate({:publication, value.message_id})

    defp load(kind) do
      record({:load, kind})
      {:ok, Process.get({RecoveryTest, kind}, [])}
    end

    defp mutate(entry) do
      record(entry)
      Map.get(Process.get({RecoveryTest, :responses}, %{}), entry, {:ok, :terminal})
    end

    defp record(entry), do: Process.put({RecoveryTest, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({RecoveryTest, :trace}, [])
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :executions}, [execution()])
    Process.put({__MODULE__, :conversations}, [conversation()])
    Process.put({__MODULE__, :publications}, [publication(1), publication(2)])

    Process.put({__MODULE__, :responses}, %{{:publication, 2} => {:error, :conflict}})

    :ok
  end

  test "loads every bounded collection before closing abandoned work once" do
    assert {:ok, %Result{} = result} = Recovery.run(@cutoff, @recovered_at, stores())

    assert result.execution_count == 1
    assert result.conversation_count == 1
    assert result.publication_count == 1
    assert result.failure_count == 1

    assert Process.get({__MODULE__, :trace}) == [
             {:load, :executions},
             {:load, :conversations},
             {:load, :publications},
             {:publication, 1},
             {:publication, 2},
             {:conversation, "conversation-a"},
             {:execution, "trigger-a"}
           ]

    refute inspect(result) =~ "publication_a"
  end

  test "rejects invalid time, stores, and oversized loads before mutation" do
    invalid_stores = Map.put(stores(), :private, true)

    assert Recovery.run(@recovered_at, @cutoff, stores()) ==
             {:error, :invalid_runtime_recovery}

    assert Recovery.run(@cutoff, @recovered_at, invalid_stores) ==
             {:error, :invalid_runtime_recovery}

    Process.put({__MODULE__, :executions}, [execution(), %TriggerExecution{}])

    assert Recovery.run(@cutoff, @recovered_at, stores()) ==
             {:error, :invalid_runtime_recovery}

    assert Process.get({__MODULE__, :trace}) == [
             {:load, :executions},
             {:load, :conversations},
             {:load, :publications}
           ]
  end

  defp stores do
    %Stores{executions: Executions, conversations: Conversations, publications: Publications}
  end

  defp execution do
    %TriggerExecution{
      trigger_id: "trigger-a",
      event_id: "event-a",
      status: :started,
      executed_at: @cutoff,
      cooldown_until: ~U[2026-08-07 02:00:00.000000Z],
      error_class: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end

  defp conversation do
    %ConversationRecord{
      id: "conversation-a",
      root_event_id: "event-a",
      status: :starting,
      turn_count: 0,
      llm_call_count: 0,
      started_at: @cutoff,
      completed_at: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end

  defp publication(message_id) do
    %PublicationAttemptRecord{
      message_id: message_id,
      status: :started,
      started_at: @cutoff,
      completed_at: nil,
      error_class: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end
end
