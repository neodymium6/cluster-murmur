defmodule ClusterMurmur.Discord.Publisher do
  @moduledoc """
  Boundary for outbound Discord publication.

  Implementations revalidate current publication inputs, durably claim one
  external dispatch, and invoke only a narrow injected transport. Outcomes
  distinguish known rejection from an unknowable effect without exposing the
  webhook URL or raw HTTP details.
  """

  alias ClusterMurmur.Discord.{WebhookRequest, WebhookResponse}
  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Persistence.PublicationAttemptRecord

  @type transport_error :: :invalid_request | :timeout | :unavailable
  @type transport_result ::
          {:ok, WebhookResponse.t()}
          | {:error, :not_sent, transport_error()}
          | {:error, :outcome_unknown}
  @type transport :: (WebhookRequest.t() -> transport_result())
  @type local_error ::
          :invalid_publication_attempt_record
          | :invalid_request
          | :publication_attempt_conflict
          | :storage_unavailable
  @type outcome ::
          {:ok, String.t(), PublicationAttemptRecord.t()}
          | {:failed, ExternalError.t(), PublicationAttemptRecord.t()}
          | {:ambiguous, :interrupted, PublicationAttemptRecord.t()}
          | {:error, local_error()}

  @callback publish(term(), term(), term(), term(), term(), transport()) :: outcome()
end
