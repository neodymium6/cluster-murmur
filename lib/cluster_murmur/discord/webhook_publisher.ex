defmodule ClusterMurmur.Discord.WebhookPublisher do
  @moduledoc """
  Claims and publishes one exact current plan through an injected transport.

  Only the caller that durably changes `started` to `dispatching` reaches the
  transport. HTTP responses that prove rejection remain known failures; any
  response or transport outcome that could follow remote acceptance is
  deliberately ambiguous.
  """

  @behaviour ClusterMurmur.Discord.Publisher

  alias ClusterMurmur.Discord.{Publisher, WebhookRequest, WebhookResponse}
  alias ClusterMurmur.Discord.PublicationPlanner.Plan

  alias ClusterMurmur.Persistence.{
    PublicationAttemptRecord,
    PublicationAttemptRecordValidator,
    PublicationAttemptStore
  }

  @known_rejections [:authentication_failed, :invalid_request, :rate_limited]

  @doc "Claims and executes one publication without returning raw transport values."
  @impl true
  @spec publish(term(), term(), term(), term(), term(), term()) :: Publisher.outcome()
  def publish(
        %PublicationAttemptRecord{} = started,
        %Plan{} = plan,
        current_record,
        current_persona,
        current_settings,
        transport
      )
      when is_function(transport, 1) do
    with :ok <- validate_started_attempt(started, current_record),
         {:ok, request} <-
           WebhookRequest.encode(plan, current_record, current_persona, current_settings),
         :ok <-
           WebhookRequest.validate(
             request,
             plan,
             current_record,
             current_persona,
             current_settings
           ),
         {:ok, dispatching} <- PublicationAttemptStore.claim_dispatch(started) do
      execute(transport, request, dispatching)
    else
      {:error, reason}
      when reason in [
             :invalid_publication_attempt_record,
             :publication_attempt_conflict,
             :storage_unavailable
           ] ->
        {:error, reason}

      _invalid_request ->
        {:error, :invalid_request}
    end
  end

  def publish(
        _started,
        _plan,
        _current_record,
        _current_persona,
        _current_settings,
        _transport
      ),
      do: {:error, :invalid_request}

  defp validate_started_attempt(
         %PublicationAttemptRecord{status: :started, message_id: message_id} = attempt,
         %{id: message_id}
       ),
       do: PublicationAttemptRecordValidator.validate(attempt)

  defp validate_started_attempt(_attempt, _current_record),
    do: {:error, :invalid_publication_attempt_record}

  defp execute(transport, request, dispatching) do
    case transport.(request) do
      {:ok, %WebhookResponse{} = response} ->
        classify_response(WebhookResponse.decode(response), dispatching)

      {:error, :not_sent, error_class} when error_class in [:timeout, :unavailable] ->
        {:failed, error_class, dispatching}

      {:error, :outcome_unknown} ->
        ambiguous(dispatching)

      _invalid_transport_result ->
        ambiguous(dispatching)
    end
  rescue
    _error -> ambiguous(dispatching)
  catch
    _kind, _reason -> ambiguous(dispatching)
  end

  defp classify_response({:ok, message_id}, dispatching),
    do: {:ok, message_id, dispatching}

  defp classify_response({:error, error_class}, dispatching)
       when error_class in @known_rejections,
       do: {:failed, error_class, dispatching}

  defp classify_response({:error, _unknown_effect}, dispatching), do: ambiguous(dispatching)

  defp ambiguous(dispatching), do: {:ambiguous, :interrupted, dispatching}
end
