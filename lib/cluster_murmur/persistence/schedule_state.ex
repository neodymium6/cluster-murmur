defmodule ClusterMurmur.Persistence.ScheduleState do
  @moduledoc """
  Redacted durable due and claim state for one recurring schedule trigger.

  Execution uses a narrow store and opaque claims rather than exposing this
  record or repository access to runtime callers.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.Config.Value
  alias ClusterMurmur.DateTimeValidator

  @derive {Inspect, only: []}
  @primary_key {:trigger_id, :string, autogenerate: false, redact: true}
  @fields [
    :trigger_id,
    :next_run_at,
    :last_run_at,
    :claim_token,
    :claim_started_at,
    :claim_expires_at
  ]
  schema "schedule_states" do
    field :next_run_at, :utc_datetime_usec, redact: true
    field :last_run_at, :utc_datetime_usec, redact: true
    field :claim_token, :string, redact: true
    field :claim_started_at, :utc_datetime_usec, redact: true
    field :claim_expires_at, :utc_datetime_usec, redact: true
  end

  @state_keys [:__meta__, :__struct__ | @fields]
  @state_key_count length(@state_keys)
  @field_count length(@fields)
  @built_metadata %Ecto.Schema.Metadata{
    state: :built,
    source: "schedule_states",
    schema: __MODULE__
  }
  @loaded_metadata %Ecto.Schema.Metadata{
    state: :loaded,
    source: "schedule_states",
    schema: __MODULE__
  }

  @type t :: %__MODULE__{
          trigger_id: String.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_run_at: DateTime.t() | nil,
          claim_token: String.t() | nil,
          claim_started_at: DateTime.t() | nil,
          claim_expires_at: DateTime.t() | nil
        }

  @doc "Builds one bounded schedule-state changeset without repository access."
  @spec changeset(t(), term()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = state, attributes)
      when is_map(attributes) and not is_struct(attributes) do
    if exact_state?(state) and bounded_attributes?(attributes) do
      state
      |> cast(attributes, @fields)
      |> validate_required([:trigger_id, :next_run_at])
      |> validate_complete_trigger_id()
      |> validate_complete_datetime(:next_run_at, false)
      |> validate_complete_datetime(:last_run_at, true)
      |> validate_complete_claim_token()
      |> validate_complete_datetime(:claim_started_at, true)
      |> validate_complete_datetime(:claim_expires_at, true)
      |> validate_run_order()
      |> validate_claim_pair()
      |> check_constraints()
    else
      invalid(state)
    end
  end

  def changeset(%__MODULE__{} = state, _attributes), do: invalid(state)

  defp validate_complete_trigger_id(changeset) do
    case Value.id(get_field(changeset, :trigger_id)) do
      {:ok, _id} -> changeset
      _failure -> add_error(changeset, :trigger_id, "is invalid")
    end
  end

  defp validate_complete_datetime(changeset, field, optional?) do
    case get_field(changeset, field) do
      nil when optional? ->
        changeset

      value ->
        if valid_datetime?(value), do: changeset, else: add_error(changeset, field, "is invalid")
    end
  end

  defp validate_complete_claim_token(changeset) do
    case get_field(changeset, :claim_token) do
      nil ->
        changeset

      token when is_binary(token) and byte_size(token) == 43 ->
        case Base.url_decode64(token, padding: false) do
          {:ok, decoded} when byte_size(decoded) == 32 -> changeset
          _failure -> add_error(changeset, :claim_token, "is invalid")
        end

      _invalid ->
        add_error(changeset, :claim_token, "is invalid")
    end
  end

  defp validate_run_order(changeset) do
    case {get_field(changeset, :last_run_at), get_field(changeset, :next_run_at)} do
      {%DateTime{} = last, %DateTime{} = next} ->
        if valid_datetime?(last) and valid_datetime?(next) and DateTime.after?(next, last),
          do: changeset,
          else: add_error(changeset, :next_run_at, "must be after last run")

      _incomplete ->
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

      {token, %DateTime{} = started, %DateTime{} = expires} when is_binary(token) ->
        if valid_datetime?(started) and valid_datetime?(expires) and
             DateTime.after?(expires, started),
           do: changeset,
           else: add_error(changeset, :claim_expires_at, "must be after claim start")

      _invalid ->
        add_error(changeset, :claim_expires_at, "must accompany a claim token")
    end
  end

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:trigger_id, name: "schedule_states_trigger_id")
    |> check_constraint(:next_run_at, name: "schedule_states_next_run_at")
    |> check_constraint(:last_run_at, name: "schedule_states_run_order")
    |> check_constraint(:claim_token, name: "schedule_states_claim_token")
    |> check_constraint(:claim_started_at, name: "schedule_states_claim_started_at")
    |> check_constraint(:claim_expires_at, name: "schedule_states_claim_pair")
    |> unique_constraint(:trigger_id)
  end

  defp valid_datetime?(value), do: DateTimeValidator.validate_storage_utc(value) == :ok

  defp exact_state?(state) do
    map_size(state) == @state_key_count and Enum.all?(@state_keys, &Map.has_key?(state, &1)) and
      state.__meta__ in [@built_metadata, @loaded_metadata]
  end

  defp bounded_attributes?(attributes) do
    map_size(attributes) <= @field_count and
      Enum.all?(Map.keys(attributes), &(&1 in @fields))
  end

  defp invalid(state) do
    state = if exact_state?(state), do: state, else: %__MODULE__{}
    state |> change() |> add_error(:base, "is invalid")
  end
end
