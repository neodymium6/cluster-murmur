defmodule ClusterMurmur.Config.IncludeResolverCwdTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.IncludeResolver
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  test "normalizes an unavailable current directory for relative config paths" do
    original_cwd = File.cwd!()

    test_root = PrivateTmpDir.create!("cluster-murmur-cwd-test")

    vanished_cwd = Path.join(test_root, "vanished")
    File.mkdir_p!(vanished_cwd)
    File.cd!(vanished_cwd)

    try do
      File.rm_rf!(vanished_cwd)

      assert IncludeResolver.resolve("cluster-murmur.yaml", []) ==
               {:error, :invalid_config_path}
    after
      File.cd!(original_cwd)
      File.rm_rf!(test_root)
    end
  end
end
