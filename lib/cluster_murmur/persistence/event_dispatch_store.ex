defmodule ClusterMurmur.Persistence.EventDispatchStore do
  @moduledoc """
  Persists one bounded, lease-protected event dispatch outbox.

  Enqueue requires the exact immutable event to exist. Available reads omit all
  claim material, claims use a fixed opaque lease, and completion compares the
  complete claim before closing the entry. No consumer or external transport
  crosses this store boundary.
  """

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{Event, Validator}

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchCandidate,
    EventDispatchClaim,
    EventDispatchReceipt,
    EventStore
  }

  alias ClusterMurmur.Repo

  @claim_lease_seconds 60
  @claim_token_bytes 32
  @max_available 100
  @candidate_keys EventDispatchCandidate.__struct__() |> Map.keys()
  @candidate_key_count length(@candidate_keys)
  @claim_keys EventDispatchClaim.__struct__() |> Map.keys()
  @claim_key_count length(@claim_keys)

  @event_fields [
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
    :labels
  ]

  @type error ::
          :dispatch_conflict
          | :event_conflict
          | :event_not_found
          | :invalid_datetime
          | :invalid_dispatch
          | :invalid_event
          | :storage_unavailable

  @doc "Enqueues one exact committed event idempotently."
  @spec enqueue(term(), term()) :: {:ok, EventDispatchReceipt.t()} | {:error, error()}
  def enqueue(%Event{} = event, %DateTime{} = enqueued_at) do
    with :ok <- Validator.validate(event),
         :ok <- validate_time(enqueued_at),
         true <- not_before_event?(enqueued_at, event),
         {:ok, persisted} <- EventStore.fetch(event.id),
         true <- identical_event?(persisted, event),
         %{valid?: true} = changeset <-
           EventDispatch.enqueue_changeset(%EventDispatch{}, event.id, enqueued_at) do
      persist_enqueue(changeset, event.id, enqueued_at)
    else
      {:error, :event_not_found} -> {:error, :event_not_found}
      {:error, :invalid_event} -> {:error, :invalid_event}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      {:error, :storage_unavailable} -> {:error, :storage_unavailable}
      false -> {:error, :event_conflict}
      _failure -> {:error, :invalid_dispatch}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def enqueue(%Event{}, _enqueued_at), do: {:error, :invalid_datetime}
  def enqueue(_event, _enqueued_at), do: {:error, :invalid_event}

  @doc "Lists at most 100 pending or expired-claim entries without claim material."
  @spec list_available(term()) ::
          {:ok, [EventDispatchCandidate.t()]} | {:error, error()}
  def list_available(now) do
    if validate_time(now) == :ok do
      query =
        from dispatch in EventDispatch,
          where:
            dispatch.enqueued_at <= ^now and
              (dispatch.status == :pending or
                 (dispatch.status == :claimed and dispatch.claim_expires_at <= ^now)),
          order_by: [asc: dispatch.enqueued_at, asc: dispatch.event_id],
          limit: @max_available,
          select: %EventDispatchCandidate{
            event_id: dispatch.event_id,
            enqueued_at: dispatch.enqueued_at
          }

      candidates = Repo.all(query)

      if Enum.all?(candidates, &valid_candidate?(&1, now)),
        do: {:ok, candidates},
        else: {:error, :invalid_dispatch}
    else
      {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Claims one exact available entry through a fixed 60-second opaque lease."
  @spec claim(term(), term()) :: {:ok, EventDispatchClaim.t()} | {:error, error()}
  def claim(%EventDispatchCandidate{} = candidate, %DateTime{} = claimed_at) do
    with :ok <- validate_time(claimed_at),
         true <- valid_candidate_shape?(candidate),
         true <- DateTime.compare(candidate.enqueued_at, claimed_at) in [:lt, :eq],
         {:ok, expires_at} <- claim_expiry(claimed_at),
         token <- generate_claim_token() do
      persist_claim(candidate, claimed_at, expires_at, token)
    else
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      _failure -> {:error, :invalid_dispatch}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def claim(%EventDispatchCandidate{}, _claimed_at), do: {:error, :invalid_datetime}
  def claim(_candidate, _claimed_at), do: {:error, :invalid_dispatch}

  @doc "Completes one exact live claim without exposing event content."
  @spec complete(term(), term()) :: {:ok, EventDispatch.t()} | {:error, error()}
  def complete(%EventDispatchClaim{} = claim, %DateTime{} = completed_at) do
    with true <- valid_claim?(claim),
         :ok <- validate_time(completed_at),
         true <- DateTime.compare(completed_at, claim.started_at) in [:eq, :gt],
         true <- DateTime.compare(completed_at, claim.expires_at) == :lt do
      persist_completion(claim, completed_at)
    else
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      _failure -> {:error, :invalid_dispatch}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  def complete(%EventDispatchClaim{}, _completed_at), do: {:error, :invalid_datetime}
  def complete(_claim, _completed_at), do: {:error, :invalid_dispatch}

  defp persist_enqueue(changeset, event_id, enqueued_at) do
    case Repo.transaction(fn -> insert_then_restore(changeset, event_id, enqueued_at) end) do
      {:ok, %EventDispatch{} = dispatch} ->
        {:ok,
         %EventDispatchReceipt{
           event_id: dispatch.event_id,
           status: dispatch.status,
           enqueued_at: dispatch.enqueued_at
         }}

      {:error, reason} when reason in [:dispatch_conflict, :invalid_dispatch] ->
        {:error, reason}

      _failure ->
        {:error, :storage_unavailable}
    end
  end

  defp insert_then_restore(changeset, event_id, enqueued_at) do
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:event_id]) do
      {:ok, _inserted_or_conflicted} ->
        case Repo.get(EventDispatch, event_id) do
          %EventDispatch{} = dispatch ->
            if valid_dispatch?(dispatch) and same_time?(dispatch.enqueued_at, enqueued_at),
              do: dispatch,
              else: Repo.rollback(:dispatch_conflict)

          nil ->
            Repo.rollback(:storage_unavailable)
        end

      {:error, _changeset} ->
        Repo.rollback(:invalid_dispatch)
    end
  end

  defp persist_claim(candidate, claimed_at, expires_at, token) do
    case Repo.transaction(fn -> claim_available(candidate, claimed_at, expires_at, token) end) do
      {:ok, %EventDispatchClaim{} = claim} -> {:ok, claim}
      {:error, :dispatch_conflict} -> {:error, :dispatch_conflict}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp claim_available(candidate, claimed_at, expires_at, token) do
    query =
      from dispatch in EventDispatch,
        where:
          dispatch.event_id == ^candidate.event_id and
            dispatch.enqueued_at == ^candidate.enqueued_at and
            (dispatch.status == :pending or
               (dispatch.status == :claimed and dispatch.claim_expires_at <= ^claimed_at))

    case Repo.update_all(query,
           set: [
             status: :claimed,
             claim_token: token,
             claim_started_at: claimed_at,
             claim_expires_at: expires_at,
             completed_at: nil
           ]
         ) do
      {1, nil} ->
        %EventDispatchClaim{
          event_id: candidate.event_id,
          enqueued_at: candidate.enqueued_at,
          token: token,
          started_at: claimed_at,
          expires_at: expires_at
        }

      {0, nil} ->
        Repo.rollback(:dispatch_conflict)

      _failure ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp persist_completion(claim, completed_at) do
    case Repo.transaction(fn -> complete_claim(claim, completed_at) end) do
      {:ok, %EventDispatch{} = dispatch} -> {:ok, dispatch}
      {:error, :dispatch_conflict} -> {:error, :dispatch_conflict}
      {:error, :invalid_dispatch} -> {:error, :invalid_dispatch}
      _failure -> {:error, :storage_unavailable}
    end
  end

  defp complete_claim(claim, completed_at) do
    query =
      from dispatch in EventDispatch,
        where:
          dispatch.event_id == ^claim.event_id and
            dispatch.enqueued_at == ^claim.enqueued_at and dispatch.status == :claimed and
            dispatch.claim_token == ^claim.token and
            dispatch.claim_started_at == ^claim.started_at and
            dispatch.claim_expires_at == ^claim.expires_at

    case Repo.update_all(query,
           set: [
             status: :completed,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil,
             completed_at: completed_at
           ]
         ) do
      {1, nil} ->
        case Repo.get(EventDispatch, claim.event_id) do
          %EventDispatch{} = dispatch ->
            if valid_dispatch?(dispatch),
              do: dispatch,
              else: Repo.rollback(:invalid_dispatch)

          nil ->
            Repo.rollback(:storage_unavailable)
        end

      {0, nil} ->
        Repo.rollback(:dispatch_conflict)

      _failure ->
        Repo.rollback(:storage_unavailable)
    end
  end

  defp valid_candidate?(%EventDispatchCandidate{} = candidate, now) do
    valid_candidate_shape?(candidate) and
      validate_time(now) == :ok and DateTime.compare(candidate.enqueued_at, now) in [:lt, :eq]
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_candidate?(_candidate, _now), do: false

  defp valid_candidate_shape?(%EventDispatchCandidate{} = candidate) do
    map_size(candidate) == @candidate_key_count and
      Enum.all?(@candidate_keys, &Map.has_key?(candidate, &1)) and
      Validator.validate_id(candidate.event_id) == :ok and
      validate_time(candidate.enqueued_at) == :ok
  end

  defp valid_candidate_shape?(_candidate), do: false

  defp valid_claim?(%EventDispatchClaim{} = claim) do
    map_size(claim) == @claim_key_count and Enum.all?(@claim_keys, &Map.has_key?(claim, &1)) and
      Validator.validate_id(claim.event_id) == :ok and validate_time(claim.enqueued_at) == :ok and
      valid_claim_token?(claim.token) and validate_time(claim.started_at) == :ok and
      validate_time(claim.expires_at) == :ok and
      DateTime.compare(claim.enqueued_at, claim.started_at) in [:lt, :eq] and
      same_time?(DateTime.add(claim.started_at, @claim_lease_seconds, :second), claim.expires_at)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_dispatch?(%EventDispatch{} = dispatch) do
    Validator.validate_id(dispatch.event_id) == :ok and validate_time(dispatch.enqueued_at) == :ok and
      valid_lifecycle?(dispatch)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_lifecycle?(%EventDispatch{
         status: :pending,
         claim_token: nil,
         claim_started_at: nil,
         claim_expires_at: nil,
         completed_at: nil
       }),
       do: true

  defp valid_lifecycle?(%EventDispatch{
         status: :claimed,
         claim_token: token,
         enqueued_at: enqueued_at,
         claim_started_at: started_at,
         claim_expires_at: expires_at,
         completed_at: nil
       }) do
    valid_claim_token?(token) and validate_time(started_at) == :ok and
      validate_time(expires_at) == :ok and
      DateTime.compare(enqueued_at, started_at) in [:lt, :eq] and
      same_time?(DateTime.add(started_at, @claim_lease_seconds, :second), expires_at)
  end

  defp valid_lifecycle?(%EventDispatch{
         status: :completed,
         claim_token: nil,
         claim_started_at: nil,
         claim_expires_at: nil,
         completed_at: completed_at,
         enqueued_at: enqueued_at
       }) do
    validate_time(completed_at) == :ok and
      DateTime.compare(completed_at, enqueued_at) in [:eq, :gt]
  end

  defp valid_lifecycle?(_dispatch), do: false

  defp validate_time(datetime), do: DateTimeValidator.validate_storage_utc(datetime)

  defp claim_expiry(claimed_at) do
    expires_at = DateTime.add(claimed_at, @claim_lease_seconds, :second)

    case validate_time(expires_at) do
      :ok -> {:ok, expires_at}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp not_before_event?(enqueued_at, event) do
    latest =
      case event.observed_at do
        nil ->
          event.occurred_at

        observed_at ->
          if DateTime.compare(observed_at, event.occurred_at) == :gt,
            do: observed_at,
            else: event.occurred_at
      end

    DateTime.compare(enqueued_at, latest) in [:eq, :gt]
  end

  defp identical_event?(persisted, supplied) do
    Map.take(persisted, @event_fields) === Map.take(supplied, @event_fields) and
      same_time?(persisted.occurred_at, supplied.occurred_at) and
      same_optional_time?(persisted.observed_at, supplied.observed_at)
  end

  defp same_time?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_time?(_left, _right), do: false
  defp same_optional_time?(nil, nil), do: true
  defp same_optional_time?(left, right), do: same_time?(left, right)

  defp valid_claim_token?(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_claim_token?(_token), do: false

  defp generate_claim_token,
    do: @claim_token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
