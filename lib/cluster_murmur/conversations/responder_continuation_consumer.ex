defmodule ClusterMurmur.Conversations.ResponderContinuationConsumer do
  @moduledoc """
  Narrow synchronous boundary for one responder continuation selection.

  Implementations preflight all context before randomness is consumed, then
  atomically consume the plan's durable responder claim before any effect. The
  dispatcher creates that exact persona-bound claim before handoff. A reply may
  return only its already-persisted delivery capability; it cannot authorize a
  second provider call.
  """

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan}
  alias ClusterMurmur.Persistence.{ConversationRecord, MessageRecord}
  alias ClusterMurmur.Persistence.{ConversationRecordValidator, MessageRecordValidator}

  defmodule Delivery do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:plan, :message, :conversation]
    defstruct [:plan, :message, :conversation]

    @type t :: %__MODULE__{
            plan: ClusterMurmur.Conversations.ResponderContinuationPlanner.Plan.t(),
            message: ClusterMurmur.Persistence.MessageRecord.t(),
            conversation: ClusterMurmur.Persistence.ConversationRecord.t()
          }
  end

  @delivery_keys Delivery.__struct__() |> Map.keys()
  @delivery_key_count length(@delivery_keys)

  @callback preflight(Input.t(), term()) :: :ok | {:error, atom()}

  @callback consume(Plan.t(), term()) ::
              :ok | {:ok, Delivery.t()} | {:error, atom()}

  @doc "Revalidates one persisted reply without making it a generation capability."
  @spec validate_delivery(term(), term()) :: :ok | {:error, :invalid_responder_delivery}
  def validate_delivery(
        %Delivery{} = delivery,
        %Plan{outcome: :reply, responder: responder} = plan
      )
      when not is_nil(responder) do
    expected_conversation = %{plan.conversation | turn_count: plan.conversation.turn_count + 1}

    with true <- exact_delivery?(delivery),
         true <- delivery.plan === plan,
         :ok <- ResponderContinuationPlanner.validate_reply_plan(plan),
         %MessageRecord{} = message <- delivery.message,
         %ConversationRecord{} = conversation <- delivery.conversation,
         :ok <- MessageRecordValidator.validate(message),
         :ok <- ConversationRecordValidator.validate_active(conversation),
         true <- message.discord_message_id === nil,
         true <- message.conversation_id === plan.conversation.id,
         true <- message.persona_id === responder.id,
         true <- DateTime.compare(message.inserted_at, plan.planned_at) in [:gt, :eq],
         true <- conversation === expected_conversation do
      :ok
    else
      _failure -> {:error, :invalid_responder_delivery}
    end
  rescue
    _error -> {:error, :invalid_responder_delivery}
  catch
    _kind, _reason -> {:error, :invalid_responder_delivery}
  end

  def validate_delivery(_delivery, _plan), do: {:error, :invalid_responder_delivery}

  defp exact_delivery?(delivery) do
    map_size(delivery) == @delivery_key_count and
      Enum.all?(@delivery_keys, &Map.has_key?(delivery, &1))
  end
end
