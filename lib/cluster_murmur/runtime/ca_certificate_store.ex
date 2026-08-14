defmodule ClusterMurmur.Runtime.CACertificateStore do
  @moduledoc """
  Initializes the bounded CA certificate store used by fixed HTTPS transports.

  When `SSL_CERT_FILE` is configured, the path must identify a non-empty,
  size-bounded regular file and is loaded into OTP before the store is read.
  Without that environment value, OTP may use its platform certificate source.
  Either path must produce a non-empty store before standalone workers start.

  Failures return one stable error and never expose the configured path,
  certificate contents, or loader details.
  """

  @certificate_file_environment "SSL_CERT_FILE"
  @max_path_bytes 4 * 1_024
  @max_bundle_bytes 4 * 1_024 * 1_024

  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)
  @type bundle_loader :: (String.t() -> :ok | {:error, term()})
  @type certificate_reader :: (-> [term()])
  @type error :: :invalid_ca_certificate_store

  @doc "Loads a configured CA bundle and verifies that OTP has usable certificates."
  @spec initialize(environment_reader(), bundle_loader(), certificate_reader()) ::
          :ok | {:error, error()}
  def initialize(
        environment_reader \\ &System.fetch_env/1,
        bundle_loader \\ &:public_key.cacerts_load/1,
        certificate_reader \\ &:public_key.cacerts_get/0
      )

  def initialize(environment_reader, bundle_loader, certificate_reader)
      when is_function(environment_reader, 1) and is_function(bundle_loader, 1) and
             is_function(certificate_reader, 0) do
    with :ok <- load_configured_bundle(environment_reader, bundle_loader),
         [_certificate | _remaining] <- certificate_reader.() do
      :ok
    else
      _failure -> {:error, :invalid_ca_certificate_store}
    end
  rescue
    _error -> {:error, :invalid_ca_certificate_store}
  catch
    _kind, _reason -> {:error, :invalid_ca_certificate_store}
  end

  def initialize(_environment_reader, _bundle_loader, _certificate_reader),
    do: {:error, :invalid_ca_certificate_store}

  defp load_configured_bundle(environment_reader, bundle_loader) do
    case environment_reader.(@certificate_file_environment) do
      {:ok, path} -> load_bundle(path, bundle_loader)
      :error -> :ok
      _invalid -> {:error, :invalid_ca_certificate_store}
    end
  end

  defp load_bundle(path, bundle_loader) do
    with :ok <- validate_path(path),
         {:ok, %File.Stat{type: :regular, size: size}} when size in 1..@max_bundle_bytes <-
           File.stat(path),
         :ok <- bundle_loader.(path) do
      :ok
    else
      _failure -> {:error, :invalid_ca_certificate_store}
    end
  end

  defp validate_path(path)
       when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    if String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(path) == :absolute do
      :ok
    else
      {:error, :invalid_ca_certificate_store}
    end
  end

  defp validate_path(_path), do: {:error, :invalid_ca_certificate_store}
end
