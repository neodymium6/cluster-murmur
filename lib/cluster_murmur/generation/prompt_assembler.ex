defmodule ClusterMurmur.Generation.PromptAssembler do
  @moduledoc """
  Assembles a validated generation context into fixed structured prompt data.

  This module does not interpolate supplied values into instructions or render
  text sections. Provider adapters may encode this structure but must preserve
  its field boundaries.
  """

  alias ClusterMurmur.Generation.{
    Context,
    ContextValidator,
    FactProjectionValidator,
    PromptRequest
  }

  @system_instruction "Express only the supplied confirmed facts in the supplied persona voice. " <>
                        "Do not invent causes, measurements, remediation, recovery, credentials, " <>
                        "endpoints, or tool activity. Return only the message text."

  @type error :: :invalid_generation_context

  @doc false
  @spec system_instruction() :: String.t()
  def system_instruction, do: @system_instruction

  @doc "Returns one redacted provider-neutral prompt request after validation."
  @spec assemble(term()) :: {:ok, PromptRequest.t()} | {:error, error()}
  def assemble(%Context{} = context) do
    with :ok <- ContextValidator.validate(context),
         {:ok, facts} <- FactProjectionValidator.to_prompt_map(context.facts) do
      {:ok,
       %PromptRequest{
         system_instruction: @system_instruction,
         persona: %{
           "display_name" => context.persona.display_name,
           "instructions" => context.persona.instructions
         },
         confirmed_facts: facts,
         creative_context: %{
           "conversation_kind" => context.creative_context.conversation_kind,
           "mood" => context.creative_context.mood
         },
         conversation:
           Enum.map(context.conversation, fn line ->
             %{"content" => line.content, "speaker" => line.speaker}
           end)
       }}
    else
      _failure -> {:error, :invalid_generation_context}
    end
  rescue
    _error -> {:error, :invalid_generation_context}
  catch
    _kind, _reason -> {:error, :invalid_generation_context}
  end

  def assemble(_context), do: {:error, :invalid_generation_context}
end
