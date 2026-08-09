defmodule ClusterMurmur.Persistence.EventDedupeMarker do
  @moduledoc """
  Redacted persistence representation of one accepted event dedupe marker.

  Construction accepts only a pristine record and one exact, bounded marker.
  Correlation with the immutable event and replacement policy remain separate
  transactional store concerns.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.DedupeEvaluator.Marker
  alias ClusterMurmur.Events.Validator

  @derive {Inspect, only: []}
  @primary_key {:dedupe_key, :string, autogenerate: false, redact: true}
  @fields [:dedupe_key, :event_id, :accepted_at]
  @marker_keys Marker.__struct__() |> Map.keys()
  @marker_key_count length(@marker_keys)

  schema "event_dedupe_markers" do
    field :event_id, :string, redact: true
    field :accepted_at, :utc_datetime_usec, redact: true
  end

  @type t :: %__MODULE__{
          dedupe_key: String.t() | nil,
          event_id: String.t() | nil,
          accepted_at: DateTime.t() | nil
        }

  @doc "Builds one redacted marker changeset from an exact pure decision."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, %Marker{} = marker) do
    if record == %__MODULE__{} and valid_marker?(marker) do
      record
      |> cast(Map.from_struct(marker), @fields)
      |> validate_required(@fields)
      |> check_constraint(:dedupe_key, name: "event_dedupe_markers_dedupe_key")
      |> check_constraint(:event_id, name: "event_dedupe_markers_event_id")
      |> check_constraint(:accepted_at, name: "event_dedupe_markers_accepted_at")
      |> unique_constraint(:dedupe_key)
    else
      invalid_changeset(record)
    end
  rescue
    _error -> invalid_changeset(record)
  catch
    _kind, _reason -> invalid_changeset(record)
  end

  def changeset(%__MODULE__{} = record, _marker), do: invalid_changeset(record)

  defp valid_marker?(marker) do
    map_size(marker) == @marker_key_count and
      Enum.all?(@marker_keys, &Map.has_key?(marker, &1)) and
      Validator.validate_id(marker.dedupe_key) == :ok and
      Validator.validate_id(marker.event_id) == :ok and
      DateTimeValidator.validate_storage_utc(marker.accepted_at) == :ok
  end

  defp invalid_changeset(record), do: record |> change() |> add_error(:base, "is invalid")
end
