defmodule Lovelace.TestSupport.SubprocessCoverage do
  @moduledoc false

  if Process.whereis(Mix.State), do: Mix.ensure_application!(:tools)

  # Separate VMs are required for managed-vault and production maintenance tests.
  # Import only counters from byte-identical BEAMs; never replace production
  # modules with test builds to make their coverage mergeable.
  def cmd(executable, arguments, options) do
    if Process.whereis(:cover_server) && :cover.modules() != [] do
      directory =
        Path.join(System.tmp_dir!(), "lovelace-cover-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      manifest = Path.join(directory, "modules.term")
      counters = Path.join(directory, "child.coverdata")

      modules =
        for module <- :cover.modules(),
            {:file, beam} = :cover.is_compiled(module),
            do: {module, :crypto.hash(:sha256, File.read!(beam))}

      File.write!(manifest, :erlang.term_to_binary(modules))

      options =
        Keyword.update(options, :env, coverage_env(manifest, counters), fn env ->
          env ++ coverage_env(manifest, counters)
        end)

      try do
        {output, status} = System.cmd(executable, arguments, options)

        if status == 0 do
          :ok = :cover.import(String.to_charlist(counters))
        end

        {output, status}
      after
        File.rm_rf!(directory)
      end
    else
      System.cmd(executable, arguments, options)
    end
  end

  def start do
    if manifest = System.get_env("LOVELACE_COVER_MANIFEST") do
      Mix.Task.run("loadpaths")
      Mix.ensure_application!(:tools)
      Mix.ensure_application!(:crypto)
      {:ok, _} = :cover.start()
      modules = manifest |> File.read!() |> :erlang.binary_to_term()

      matching =
        for {module, digest} <- modules,
            beam when is_list(beam) and beam != [] <- [:code.which(module)],
            ^digest <- [:crypto.hash(:sha256, File.read!(beam))],
            do: {module, beam}

      # Submit the complete set once so OTP can instrument it with its bounded
      # worker pool, rather than serializing one compilation per server call.
      beams = Enum.map(matching, &elem(&1, 1))
      expected = matching |> Enum.map(fn {module, _beam} -> {:ok, module} end) |> Enum.sort()
      results = beams |> :cover.compile_beam() |> Enum.sort()

      unless results == expected,
        do: raise("Subprocess coverage compilation failed: #{inspect(results)}")

      System.at_exit(fn _ ->
        path = System.fetch_env!("LOVELACE_COVER_COUNTERS")
        :ok = :cover.export(String.to_charlist(path))
      end)
    end

    :ok
  end

  defp coverage_env(manifest, counters),
    do: [{"LOVELACE_COVER_MANIFEST", manifest}, {"LOVELACE_COVER_COUNTERS", counters}]
end
