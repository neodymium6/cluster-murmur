defmodule ClusterMurmur.Persistence.StochasticSchedule do
  @moduledoc """
  Persistence record for one restart-safe stochastic trigger schedule.

  Runtime scheduling uses a dedicated store boundary rather than exposing this
  Ecto record or the repository directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Config.Value

  @derive {Inspect, only: []}
  @primary_key {:trigger_id, :string, autogenerate: false, redact: true}
  @max_trigger_id_bytes 16 * 1_024
  @max_daily_count 10_000
  @attribute_keys [
    :trigger_id,
    :next_run_at,
    :last_run_at,
    :daily_count,
    :daily_count_date,
    :claim_token,
    :claim_started_at,
    :claim_expires_at
  ]
  @string_attribute_keys Enum.map(@attribute_keys, &Atom.to_string/1)

  schema "stochastic_schedules" do
    field :next_run_at, :utc_datetime_usec, redact: true
    field :last_run_at, :utc_datetime_usec, redact: true
    field :daily_count, :integer, default: 0, redact: true
    field :daily_count_date, :date, redact: true
    field :claim_token, :string, redact: true
    field :claim_started_at, :utc_datetime_usec, redact: true
    field :claim_expires_at, :utc_datetime_usec, redact: true
  end

  @type t :: %__MODULE__{
          trigger_id: String.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          daily_count: non_neg_integer(),
          daily_count_date: Date.t() | nil,
          claim_token: String.t() | nil,
          claim_started_at: DateTime.t() | nil,
          claim_expires_at: DateTime.t() | nil
        }

  @doc "Builds a bounded persistence changeset without reading or writing the repository."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = schedule, attributes) do
    if valid_attribute_container?(attributes),
      do: build_changeset(schedule, attributes),
      else: invalid_changeset(schedule)
  end

  defp build_changeset(schedule, attributes) do
    schedule
    |> cast(attributes, @attribute_keys)
    |> validate_required([:trigger_id, :next_run_at, :daily_count])
    |> validate_change(:trigger_id, &validate_trigger_id/2)
    |> validate_change(:next_run_at, &validate_storage_year/2)
    |> validate_change(:last_run_at, &validate_storage_year/2)
    |> validate_change(:daily_count_date, &validate_storage_year/2)
    |> validate_change(:claim_token, &validate_claim_token/2)
    |> validate_change(:claim_started_at, &validate_storage_year/2)
    |> validate_change(:claim_expires_at, &validate_storage_year/2)
    |> validate_number(:daily_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_daily_count
    )
    |> validate_run_order()
    |> validate_daily_bucket()
    |> validate_claim_pair()
    |> check_constraint(:trigger_id, name: "stochastic_schedules_trigger_id")
    |> check_constraint(:next_run_at, name: "stochastic_schedules_next_run_at")
    |> check_constraint(:last_run_at, name: "stochastic_schedules_run_order")
    |> check_constraint(:daily_count, name: "stochastic_schedules_daily_count_bounds")
    |> check_constraint(:daily_count_date, name: "stochastic_schedules_daily_bucket")
    |> check_constraint(:claim_token, name: "stochastic_schedules_claim_token")
    |> check_constraint(:claim_started_at, name: "stochastic_schedules_claim_started_at")
    |> check_constraint(:claim_expires_at, name: "stochastic_schedules_claim_pair")
  end

  defp invalid_changeset(schedule) do
    schedule
    |> change()
    |> add_error(:base, "is invalid")
  end

  defp valid_attribute_container?(attributes)
       when is_map(attributes) and not is_struct(attributes) do
    keys = Map.keys(attributes)
    Enum.all?(keys, &(&1 in @attribute_keys)) or Enum.all?(keys, &(&1 in @string_attribute_keys))
  end

  defp valid_attribute_container?(_attributes), do: false

  defp validate_trigger_id(:trigger_id, trigger_id)
       when byte_size(trigger_id) > @max_trigger_id_bytes,
       do: [trigger_id: "is invalid"]

  defp validate_trigger_id(:trigger_id, trigger_id) do
    case Value.id(trigger_id) do
      {:ok, _id} -> []
      _failure -> [trigger_id: "is invalid"]
    end
  end

  defp validate_storage_year(_field, %{year: year}) when year in 0..9999, do: []
  defp validate_storage_year(field, _value), do: [{field, "has an unsupported year"}]

  defp validate_claim_token(:claim_token, token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> []
      _failure -> [claim_token: "is invalid"]
    end
  end

  defp validate_run_order(changeset) do
    case {get_field(changeset, :last_run_at), get_field(changeset, :next_run_at)} do
      {%DateTime{} = last_run_at, %DateTime{} = next_run_at} ->
        if DateTime.compare(next_run_at, last_run_at) == :gt,
          do: changeset,
          else: add_error(changeset, :next_run_at, "must be after last run")

      _incomplete ->
        changeset
    end
  end

  defp validate_daily_bucket(changeset) do
    case {get_field(changeset, :daily_count), get_field(changeset, :daily_count_date)} do
      {daily_count, nil} when is_integer(daily_count) and daily_count > 0 ->
        add_error(changeset, :daily_count_date, "is required for a positive count")

      _valid_or_incomplete ->
        changeset
    end
  end

  defp validate_claim_pair(changeset) do
    case {
      get_field(changeset, :claim_token),
      get_field(changeset, :claim_started_at),
      get_field(changeset, :claim_expires_at)
    } do
      {nil, nil, nil} ->
        changeset

      {token, %DateTime{} = started_at, %DateTime{} = expires_at} when is_binary(token) ->
        if DateTime.compare(expires_at, started_at) == :gt,
          do: changeset,
          else: add_error(changeset, :claim_expires_at, "must be after claim start")

      _invalid ->
        add_error(changeset, :claim_expires_at, "must accompany a claim token")
    end
  end
end
