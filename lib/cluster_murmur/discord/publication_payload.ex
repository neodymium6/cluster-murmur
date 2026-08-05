defmodule ClusterMurmur.Discord.PublicationPayload do
  @moduledoc """
  A fixed validated Discord webhook publication body.

  The payload contains only one generated message and its selected persona's
  publication identity. Mention parsing is always disabled. Webhook credentials
  and execution parameters are deliberately absent.
  """

  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Messages.Validator, as: MessageValidator
  alias ClusterMurmur.Personas.Persona
  alias ClusterMurmur.Personas.Validator, as: PersonaValidator

  @max_content_characters 2_000
  @max_username_characters 80

  @derive {Inspect, only: []}
  @enforce_keys [:content, :username, :avatar_url, :allowed_mentions]
  defstruct [:content, :username, :avatar_url, :allowed_mentions]

  @type t :: %__MODULE__{
          content: String.t(),
          username: String.t(),
          avatar_url: String.t() | nil,
          allowed_mentions: %{required(:parse) => []}
        }

  @type error :: :invalid_publication_payload

  @doc "Builds one outbound-only payload from an unpublished message and its persona."
  @spec build(term(), term()) :: {:ok, t()} | {:error, error()}
  def build(%Message{} = message, %Persona{} = persona) do
    with :ok <- MessageValidator.validate(message),
         :ok <- PersonaValidator.validate(persona),
         true <- message.discord_message_id == nil,
         true <- message.persona_id == persona.id,
         true <- persona.enabled == true,
         true <- String.length(message.content) <= @max_content_characters,
         true <- String.length(persona.display_name) <= @max_username_characters do
      {:ok,
       %__MODULE__{
         content: message.content,
         username: persona.display_name,
         avatar_url: persona.avatar,
         allowed_mentions: %{parse: []}
       }}
    else
      _failure -> {:error, :invalid_publication_payload}
    end
  rescue
    _error -> {:error, :invalid_publication_payload}
  catch
    _kind, _reason -> {:error, :invalid_publication_payload}
  end

  def build(_message, _persona), do: {:error, :invalid_publication_payload}
end
