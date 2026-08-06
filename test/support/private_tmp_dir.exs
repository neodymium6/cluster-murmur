defmodule ClusterMurmur.TestSupport.PrivateTmpDir do
  @moduledoc false

  @suffix_bytes 18

  def create!(prefix) when is_binary(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{random_suffix()}")

    case File.mkdir(root) do
      :ok ->
        File.chmod!(root, 0o700)
        root

      {:error, :eexist} ->
        create!(prefix)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create directory", path: root
    end
  end

  defp random_suffix do
    @suffix_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
