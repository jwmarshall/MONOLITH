defmodule Lovelace.Security.DeveloperSetupTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lovelace.Keychain.Build

  setup do
    root =
      Path.join(System.tmp_dir!(), "lovelace-helper-setup-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    source = Path.join(root, "keychain.swift")
    output = Path.join(root, "lovelace-vault")
    File.write!(source, "synthetic source")
    {:ok, root: root, source: source, output: output}
  end

  test "an existing current helper keeps its bytes and ACL-bearing inode", context do
    File.write!(context.output, "existing helper identity")
    File.chmod!(context.output, 0o755)
    File.touch!(context.source, 1_000_000_000)
    File.touch!(context.output, 1_000_000_001)
    original = File.stat!(context.output)

    Build.with_test_builder(context.source, context.output, fn _, _ ->
      flunk("setup must not invoke the compiler for an existing helper")
    end)

    assert File.read!(context.output) == "existing helper identity"
    assert File.stat!(context.output).inode == original.inode
    assert File.stat!(context.output).mtime == original.mtime
    assert File.stat!(context.output).mode == original.mode
  end

  test "a missing helper is built without running it", context do
    Build.with_test_builder(context.source, context.output, fn source, staged ->
      assert source == context.source
      assert staged != context.output
      File.write!(staged, "synthetic executable; never run")
      File.chmod!(staged, 0o755)
    end)

    assert File.read!(context.output) == "synthetic executable; never run"
    assert File.stat!(context.output).type == :regular
    assert Path.wildcard(Path.join(context.root, ".lovelace-vault-build-*")) == []
  end

  test "stale helpers require an explicit rebuild without changing identity", context do
    File.write!(context.output, "old helper identity")
    File.chmod!(context.output, 0o755)
    File.touch!(context.output, 1_000_000_000)
    File.touch!(context.source, 1_000_000_001)
    original = File.stat!(context.output)

    assert_raise Mix.Error, fn ->
      Build.with_test_builder(context.source, context.output, fn _, _ ->
        flunk("setup must not rebuild a stale helper")
      end)
    end

    assert File.read!(context.output) == "old helper identity"
    assert File.stat!(context.output).inode == original.inode
    assert File.stat!(context.output).mtime == original.mtime
    assert File.stat!(context.output).mode == original.mode
  end

  test "non-executable and symbolic-link helper paths are preserved and rejected", context do
    File.write!(context.output, "not executable")
    File.chmod!(context.output, 0o644)

    builder = fn _, _ -> flunk("unsafe existing paths must not invoke the compiler") end

    assert_raise Mix.Error, fn ->
      Build.with_test_builder(context.source, context.output, builder)
    end

    assert File.read!(context.output) == "not executable"

    link = Path.join(context.root, "linked-helper")
    File.ln_s!(context.output, link)

    assert_raise Mix.Error, fn ->
      Build.with_test_builder(context.source, link, builder)
    end

    assert File.read_link!(link) == context.output
    assert File.read!(context.output) == "not executable"
  end

  test "a helper appearing during compilation is never overwritten", context do
    assert_raise Mix.Error, fn ->
      Build.with_test_builder(context.source, context.output, fn _, staged ->
        File.write!(staged, "newly compiled helper")
        File.write!(context.output, "concurrent helper identity")
      end)
    end

    assert File.read!(context.output) == "concurrent helper identity"
    assert Path.wildcard(Path.join(context.root, ".lovelace-vault-build-*")) == []
  end
end
