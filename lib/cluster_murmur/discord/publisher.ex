defmodule ClusterMurmur.Discord.Publisher do
  @moduledoc """
  Boundary for outbound Discord publication.

  Implementations receive a bounded message payload and return only the
  published message ID or a stable error class. They must not expose the
  configured webhook URL or raw HTTP details through return values or logs.
  """

  alias ClusterMurmur.Discord.PublicationPayload
  alias ClusterMurmur.ExternalError

  @callback publish(PublicationPayload.t()) ::
              {:ok, String.t()} | {:error, ExternalError.t()}
end
