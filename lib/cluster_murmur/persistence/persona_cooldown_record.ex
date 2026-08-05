defmodule ClusterMurmur.Persistence.PersonaCooldownRecord do
  @moduledoc """
  Redacted durable selection cooldown for one persona.

  Construction accepts only a pristine record, one bounded portable persona
  ID, and canonical UTC instants whose cooldown is not earlier than the last
  spoken instant. Selection and update policy remain separate store concerns.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.{DateTimeValidator, DomainLimits}

  @derive {Inspect, only: []}
  @primary_key {:persona_id, :string, autogenerate: false, redact: true}
  @fields [:persona_id, :cooldown_until, :last_spoken_at]
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_id_bytes DomainLimits.max_id_bytes()
  @max_cooldown_microseconds DomainLimits.max_interval_ms() * 1_000

  schema "persona_cooldowns" do
    field :cooldown_until, :utc_datetime_usec, redact: true
    field :last_spoken_at, :utc_datetime_usec, redact: true
  end

  @type t :: %__MODULE__{
          persona_id: String.t() | nil,
          cooldown_until: DateTime.t() | nil,
          last_spoken_at: DateTime.t() | nil
        }

  @doc "Builds one redacted persona-cooldown changeset from explicit bounded facts."
  @spec changeset(t(), term(), term(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, persona_id, last_spoken_at, cooldown_until) do
    if pristine_record?(record) and valid_persona_id?(persona_id) and
         valid_datetime?(last_spoken_at) and valid_datetime?(cooldown_until) and
         DateTime.diff(cooldown_until, last_spoken_at, :microsecond) in 0..@max_cooldown_microseconds do
      record
      |> cast(
        %{
          persona_id: persona_id,
          cooldown_until: cooldown_until,
          last_spoken_at: last_spoken_at
        },
        @fields
      )
      |> validate_required(@fields)
      |> check_constraints()
      |> unique_constraint(:persona_id)
    else
      invalid_changeset(record)
    end
  rescue
    _error -> invalid_changeset(record)
  catch
    _kind, _reason -> invalid_changeset(record)
  end

  defp pristine_record?(record), do: record == %__MODULE__{}

  defp valid_persona_id?(persona_id)
       when is_binary(persona_id) and byte_size(persona_id) in 1..@max_id_bytes do
    String.valid?(persona_id) and Regex.match?(@id_pattern, persona_id)
  end

  defp valid_persona_id?(_persona_id), do: false

  defp valid_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:persona_id, name: "persona_cooldowns_persona_id")
    |> check_constraint(:last_spoken_at, name: "persona_cooldowns_last_spoken_at")
    |> check_constraint(:cooldown_until, name: "persona_cooldowns_cooldown_until")
  end

  defp invalid_changeset(record) do
    record
    |> change()
    |> add_error(:base, "is invalid")
  end
end
