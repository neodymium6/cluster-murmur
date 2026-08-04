defmodule ClusterMurmur.Config.Value do
  @moduledoc """
  Validates scalar values shared by version 1 configuration documents.

  The functions preserve valid values and return stable error classes without
  echoing the rejected configuration value.
  """

  @type validation_error ::
          :invalid_id | :invalid_positive_integer | :invalid_probability | :invalid_weight

  @spec id(term()) :: {:ok, String.t()} | {:error, :invalid_id}
  def id(value) when is_binary(value) do
    if valid_id?(value), do: {:ok, value}, else: {:error, :invalid_id}
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

  defp valid_id?(value) do
    value != "" and String.valid?(value) and value == String.trim(value) and
      not Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, value)
  end
end
