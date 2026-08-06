defmodule ClusterMurmur.Config.PromptReaderTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.PromptReader
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  setup do
    test_root = PrivateTmpDir.create!("cluster-murmur-prompt-test")

    config_root = Path.join(test_root, "config")
    config_file = write_fixture(config_root, "cluster-murmur.yaml", "version: 1\n")
    source_file = write_fixture(config_root, "personas/observer.yaml", "personas: []\n")

    on_exit(fn -> File.rm_rf!(test_root) end)

    %{
      config_file: config_file,
      config_root: config_root,
      source_file: source_file,
      test_root: test_root
    }
  end

  test "reads a relative non-empty UTF-8 prompt", context do
    prompt = "You are a careful observer.\n"
    write_fixture(context.config_root, "prompts/observer.md", prompt)

    assert PromptReader.read(
             context.config_file,
             context.source_file,
             "../prompts/observer.md"
           ) == {:ok, prompt}
  end

  test "accepts exactly 64 KiB and rejects larger prompts", context do
    exact = String.duplicate("a", 64 * 1_024)
    write_fixture(context.config_root, "prompts/exact.md", exact)
    write_fixture(context.config_root, "prompts/large.md", exact <> "b")

    assert PromptReader.read(context.config_file, context.source_file, "../prompts/exact.md") ==
             {:ok, exact}

    assert PromptReader.read(context.config_file, context.source_file, "../prompts/large.md") ==
             {:error, :prompt_too_large}
  end

  test "rejects empty and invalid UTF-8 prompts", context do
    write_fixture(context.config_root, "prompts/empty.md", "")
    write_fixture(context.config_root, "prompts/invalid.md", <<255>>)

    assert PromptReader.read(context.config_file, context.source_file, "../prompts/empty.md") ==
             {:error, :empty_prompt}

    assert PromptReader.read(context.config_file, context.source_file, "../prompts/invalid.md") ==
             {:error, :invalid_prompt_encoding}
  end

  test "rejects invalid and oversized references", context do
    invalid_references = [
      nil,
      "",
      "/tmp/prompt.md",
      "prompts/*.md",
      "prompts//observer.md",
      "prompts/observer.md/",
      "prompts/観測者.md",
      <<255>>
    ]

    for reference <- invalid_references do
      assert PromptReader.read(context.config_file, context.source_file, reference) ==
               {:error, :invalid_prompt_reference}
    end

    oversized = String.duplicate("a", 510) <> ".md"

    assert PromptReader.read(context.config_file, context.source_file, oversized) ==
             {:error, :prompt_reference_too_long}
  end

  test "rejects direct and symlink escapes from the configuration root", context do
    outside = write_fixture(context.test_root, "private.md", "private prompt")
    link = Path.join(context.config_root, "prompts/outside.md")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(outside, link)

    assert PromptReader.read(context.config_file, context.source_file, "../../private.md") ==
             {:error, :prompt_target_outside_root}

    assert PromptReader.read(
             context.config_file,
             context.source_file,
             "../prompts/outside.md"
           ) == {:error, :prompt_target_outside_root}
  end

  test "allows a symlink whose canonical prompt stays inside the root", context do
    prompt = "Shared public persona prompt."
    target = write_fixture(context.config_root, ".data/observer.md", prompt)
    link = Path.join(context.config_root, "prompts/observer.md")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(target, link)

    assert PromptReader.read(
             context.config_file,
             context.source_file,
             "../prompts/observer.md"
           ) == {:ok, prompt}
  end

  test "rejects missing files, directories, dangling links, and symlink loops", context do
    directory = Path.join(context.config_root, "prompts/directory")
    File.mkdir_p!(directory)
    File.ln_s!("missing.md", Path.join(context.config_root, "prompts/dangling.md"))
    File.ln_s!("second.md", Path.join(context.config_root, "prompts/first.md"))
    File.ln_s!("first.md", Path.join(context.config_root, "prompts/second.md"))

    for reference <- [
          "../prompts/missing.md",
          "../prompts/directory",
          "../prompts/dangling.md",
          "../prompts/first.md"
        ] do
      assert PromptReader.read(context.config_file, context.source_file, reference) ==
               {:error, :prompt_target_invalid}
    end
  end

  test "bounds symlink expansion", context do
    write_fixture(context.config_root, "prompts/target.md", "bounded")

    for number <- 1..41 do
      target = if number == 41, do: "target.md", else: "link#{number + 1}.md"
      File.ln_s!(target, Path.join(context.config_root, "prompts/link#{number}.md"))
    end

    assert PromptReader.read(context.config_file, context.source_file, "../prompts/link1.md") ==
             {:error, :prompt_target_invalid}
  end

  test "rejects invalid configuration and source paths", context do
    prompt = write_fixture(context.config_root, "prompts/observer.md", "prompt")
    outside_source = write_fixture(context.test_root, "outside.yaml", "personas: []\n")

    assert PromptReader.read("missing.yaml", context.source_file, "../prompts/observer.md") ==
             {:error, :invalid_config_path}

    assert PromptReader.read(nil, context.source_file, "../prompts/observer.md") ==
             {:error, :invalid_config_path}

    assert PromptReader.read(context.config_file, outside_source, "config/prompts/observer.md") ==
             {:error, :invalid_source_path}

    assert PromptReader.read(context.config_file, nil, "../prompts/observer.md") ==
             {:error, :invalid_source_path}

    assert PromptReader.read(context.config_file, prompt, nil) ==
             {:error, :invalid_prompt_reference}
  end

  test "errors do not expose prompt contents or paths", context do
    private_path = write_fixture(context.test_root, "private-prompt.md", "private prompt")

    result =
      PromptReader.read(
        context.config_file,
        context.source_file,
        "../../private-prompt.md"
      )

    assert result == {:error, :prompt_target_outside_root}
    refute inspect(result) =~ private_path
    refute inspect(result) =~ "private prompt"
  end

  defp write_fixture(root, relative_path, contents) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Path.expand(path)
  end
end
