defmodule ClusterMurmur.Generation.PromptRequest do
  @moduledoc """
  Provider-neutral structured prompt assembled from validated generation input.

  The fixed application instruction, persona instruction, confirmed facts,
  creative context, and conversation history remain separate fields so data is
  never interpreted as a section delimiter during assembly.
  """

  @derive {Inspect, only: []}
  @enforce_keys [
    :system_instruction,
    :persona,
    :confirmed_facts,
    :creative_context,
    :conversation
  ]
  defstruct [
    :system_instruction,
    :persona,
    :confirmed_facts,
    :creative_context,
    :conversation
  ]

  @type t :: %__MODULE__{
          system_instruction: String.t(),
          persona: %{required(String.t()) => String.t()},
          confirmed_facts: map(),
          creative_context: %{required(String.t()) => String.t()},
          conversation: [%{required(String.t()) => String.t()}]
        }
end
