defmodule ClusterMurmur.Persistence.EventRecord do
  @moduledoc """
  Redacted persistence representation of one bounded immutable event.

  JSON-compatible domain values are encoded only after the complete event has
  passed the shared event validator. Repository access remains in a dedicated
  future store boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Events.{Event, Validator}

  @derive {Inspect, only: []}
  @primary_key {:id, :string, autogenerate: false, redact: true}
  @max_encoded_payload_bytes 512 * 1_024
  @max_string_bytes 16 * 1_024
  @fields [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :dedupe_key,
    :correlation_key,
    :facts,
    :labels,
    :occurred_at,
    :observed_at
  ]
  @text_fields [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :dedupe_key,
    :correlation_key
  ]

  schema "events" do
    field :type, :string, redact: true
    field :source, :string, redact: true
    field :subject, :string, redact: true
    field :group, :string, redact: true
    field :severity, :string, redact: true
    field :previous, :string, redact: true
    field :current, :string, redact: true
    field :dedupe_key, :string, redact: true
    field :correlation_key, :string, redact: true
    field :facts, :string, redact: true
    field :labels, :string, redact: true
    field :occurred_at, :utc_datetime_usec, redact: true
    field :observed_at, :utc_datetime_usec, redact: true

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: String.t() | nil,
          source: String.t() | nil,
          subject: String.t() | nil,
          group: String.t() | nil,
          severity: String.t() | nil,
          previous: String.t() | nil,
          current: String.t() | nil,
          dedupe_key: String.t() | nil,
          correlation_key: String.t() | nil,
          facts: String.t() | nil,
          labels: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          observed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc "Builds a redacted persistence changeset from one fully validated event."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, %Event{} = event) do
    with :ok <- Validator.validate(event),
         {:ok, attributes} <- encode_attributes(event) do
      build_changeset(record, attributes)
    else
      _failure -> invalid_changeset(record)
    end
  end

  def changeset(%__MODULE__{} = record, _event), do: invalid_changeset(record)

  defp encode_attributes(event) do
    with {:ok, previous} <- encode_optional(event.previous),
         {:ok, current} <- encode_optional(event.current),
         {:ok, facts} <- encode_json(event.facts),
         {:ok, labels} <- encode_json(event.labels) do
      {:ok,
       %{
         id: event.id,
         type: event.type,
         source: event.source,
         subject: event.subject,
         group: event.group,
         severity: event.severity,
         previous: previous,
         current: current,
         dedupe_key: event.dedupe_key,
         correlation_key: event.correlation_key,
         facts: facts,
         labels: labels,
         occurred_at: event.occurred_at,
         observed_at: event.observed_at
       }}
    end
  end

  defp encode_optional(nil), do: {:ok, nil}
  defp encode_optional(value), do: encode_json(value)

  defp encode_json(value) do
    {:ok, value |> normalize_nulls() |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    _error -> {:error, :invalid_event}
  catch
    _kind, _reason -> {:error, :invalid_event}
  end

  defp normalize_nulls(nil), do: :null

  defp normalize_nulls(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, normalize_nulls(nested)} end)

  defp normalize_nulls(value) when is_list(value), do: Enum.map(value, &normalize_nulls/1)
  defp normalize_nulls(value), do: value

  defp build_changeset(record, attributes) do
    record
    |> cast(attributes, @fields)
    |> validate_required([:id, :type, :source, :facts, :labels, :occurred_at])
    |> validate_text_fields()
    |> validate_change(:occurred_at, &validate_storage_year/2)
    |> validate_change(:observed_at, &validate_storage_year/2)
    |> validate_encoded_payload()
    |> check_constraint(:id, name: "events_id")
    |> check_constraint(:type, name: "events_type")
    |> check_constraint(:source, name: "events_source")
    |> check_constraint(:subject, name: "events_subject")
    |> check_constraint(:group, name: "events_group")
    |> check_constraint(:severity, name: "events_severity")
    |> check_constraint(:dedupe_key, name: "events_dedupe_key")
    |> check_constraint(:correlation_key, name: "events_correlation_key")
    |> check_constraint(:previous, name: "events_previous")
    |> check_constraint(:current, name: "events_current")
    |> check_constraint(:facts, name: "events_facts")
    |> check_constraint(:labels, name: "events_payload")
    |> check_constraint(:occurred_at, name: "events_occurred_at")
    |> check_constraint(:observed_at, name: "events_observed_at")
    |> check_constraint(:inserted_at, name: "events_inserted_at")
  end

  defp invalid_changeset(record) do
    record
    |> change()
    |> add_error(:base, "is invalid")
  end

  defp validate_text_fields(changeset) do
    Enum.reduce(@text_fields, changeset, fn field, current ->
      validate_change(current, field, &validate_text/2)
    end)
  end

  defp validate_text(field, value)
       when is_binary(value) and byte_size(value) in 1..@max_string_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: [],
      else: [{field, "is invalid"}]
  end

  defp validate_text(field, _value), do: [{field, "is invalid"}]

  defp validate_storage_year(_field, %{year: year}) when year in 0..9999, do: []
  defp validate_storage_year(field, _value), do: [{field, "has an unsupported year"}]

  defp validate_encoded_payload(changeset) do
    payload_bytes =
      Enum.reduce([:previous, :current, :facts, :labels], 0, fn field, total ->
        case get_field(changeset, field) do
          value when is_binary(value) -> total + byte_size(value)
          _absent_or_invalid -> total
        end
      end)

    if payload_bytes <= @max_encoded_payload_bytes,
      do: changeset,
      else: add_error(changeset, :base, "payload is too large")
  end
end
