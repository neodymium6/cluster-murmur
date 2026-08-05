defmodule ClusterMurmur.Persistence.EntityStateRecord do
  @moduledoc """
  Redacted persistence representation of one validated observation entity state.

  Repository reads and monotonic replacement remain separate store concerns.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator}

  @derive {Inspect, only: [:current_state, :pending_state, :consecutive_count]}
  @primary_key false
  @fields [
    :source,
    :subject,
    :current_state,
    :pending_state,
    :consecutive_count,
    :last_observed_at,
    :last_changed_at,
    :facts,
    :labels
  ]
  @max_encoded_payload_bytes 128 * 1_024

  schema "entity_states" do
    field :source, :string, primary_key: true, redact: true
    field :subject, :string, primary_key: true, redact: true
    field :current_state, Ecto.Enum, values: [:unknown, :healthy, :unhealthy]
    field :pending_state, Ecto.Enum, values: [:healthy, :unhealthy]
    field :consecutive_count, :integer
    field :last_observed_at, :utc_datetime_usec, redact: true
    field :last_changed_at, :utc_datetime_usec, redact: true
    field :facts, :string, redact: true
    field :labels, :string, redact: true
  end

  @type t :: %__MODULE__{
          source: String.t() | nil,
          subject: String.t() | nil,
          current_state: EntityState.committed_state() | nil,
          pending_state: EntityState.observed_state() | nil,
          consecutive_count: non_neg_integer() | nil,
          last_observed_at: DateTime.t() | nil,
          last_changed_at: DateTime.t() | nil,
          facts: String.t() | nil,
          labels: String.t() | nil
        }

  @doc "Builds a redacted persistence changeset from one validated entity state."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, %EntityState{} = state) do
    with true <- record == %__MODULE__{},
         :ok <- EntityStateValidator.validate(state),
         {:ok, facts, labels} <- EntityStateValidator.encode_payloads(state.facts, state.labels) do
      record
      |> cast(
        %{
          source: state.source,
          subject: state.subject,
          current_state: state.current_state,
          pending_state: state.pending_state,
          consecutive_count: state.consecutive_count,
          last_observed_at: state.last_observed_at,
          last_changed_at: state.last_changed_at,
          facts: facts,
          labels: labels
        },
        @fields
      )
      |> validate_required([
        :source,
        :subject,
        :current_state,
        :consecutive_count,
        :last_observed_at,
        :facts,
        :labels
      ])
      |> validate_encoded_payload()
      |> check_constraints()
    else
      _failure -> invalid_changeset(record)
    end
  rescue
    _error -> invalid_changeset(record)
  catch
    _kind, _reason -> invalid_changeset(record)
  end

  def changeset(%__MODULE__{} = record, _state), do: invalid_changeset(record)

  defp validate_encoded_payload(changeset) do
    bytes =
      Enum.reduce([:facts, :labels], 0, fn field, total ->
        case get_field(changeset, field) do
          value when is_binary(value) -> total + byte_size(value)
          _invalid -> total
        end
      end)

    if bytes <= @max_encoded_payload_bytes,
      do: changeset,
      else: add_error(changeset, :base, "payload is too large")
  end

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:source, name: "entity_states_source")
    |> check_constraint(:subject, name: "entity_states_subject")
    |> check_constraint(:current_state, name: "entity_states_current_state")
    |> check_constraint(:pending_state, name: "entity_states_pending_progress")
    |> check_constraint(:last_observed_at, name: "entity_states_last_observed_at")
    |> check_constraint(:last_changed_at, name: "entity_states_last_changed_at")
    |> check_constraint(:facts, name: "entity_states_facts")
    |> check_constraint(:labels, name: "entity_states_payload")
    |> unique_constraint([:source, :subject])
  end

  defp invalid_changeset(record) do
    record
    |> change()
    |> add_error(:base, "is invalid")
  end
end
