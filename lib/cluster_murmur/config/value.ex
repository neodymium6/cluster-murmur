defmodule ClusterMurmur.Config.Value do
  @moduledoc """
  Validates scalar values shared by version 1 configuration documents.

  The functions preserve valid values and return stable error classes without
  echoing the rejected configuration value.
  """

  alias ClusterMurmur.DomainLimits

  @type validation_error ::
          :invalid_environment_variable_name
          | :invalid_id
          | :invalid_positive_integer
          | :invalid_probability
          | :invalid_weight

  @max_environment_variable_name_bytes 128
  @max_id_bytes DomainLimits.max_id_bytes()

  @spec environment_variable_name(term()) ::
          {:ok, String.t()} | {:error, :invalid_environment_variable_name}
  def environment_variable_name(value) when is_binary(value) do
    if byte_size(value) <= @max_environment_variable_name_bytes and String.valid?(value) and
         Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value) do
      {:ok, value}
    else
      {:error, :invalid_environment_variable_name}
    end
  end

  def environment_variable_name(_value), do: {:error, :invalid_environment_variable_name}

  @spec id(term()) :: {:ok, String.t()} | {:error, :invalid_id}
  def id(value) when is_binary(value) do
    if byte_size(value) <= @max_id_bytes and String.valid?(value) and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value) do
      {:ok, value}
    else
      {:error, :invalid_id}
    end
  end

  def id(_value), do: {:error, :invalid_id}

  @spec positive_integer(term()) :: {:ok, pos_integer()} | {:error, :invalid_positive_integer}
  def positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  def positive_integer(_value), do: {:error, :invalid_positive_integer}

  @spec probability(term()) :: {:ok, number()} | {:error, :invalid_probability}
  def probability(value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value}

  def probability(_value), do: {:error, :invalid_probability}

  @spec weight(term()) :: {:ok, number()} | {:error, :invalid_weight}
  def weight(value) when is_number(value) and value >= 0, do: {:ok, value}
  def weight(_value), do: {:error, :invalid_weight}
end
