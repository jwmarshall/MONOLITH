defmodule Lovelace.Architecture.Source do
  @moduledoc false

  # Parse, never expand/evaluate application macros. The index is deliberately
  # usable without starting LOVELACE, loading credentials or opening a Repo.
  def parse!(sources) do
    Enum.reduce(
      Enum.sort(sources),
      %{references: [], calls: [], definitions: MapSet.new(), async: [], workers: MapSet.new()},
      fn
        {file, source}, index ->
          ast = Code.string_to_quoted!(source, file: file, columns: true)

          walk(
            ast,
            %{module: nil, function: nil, aliases: %{}, imports: [], persistence: false},
            file,
            index
          )
      end
    )
  end

  defp walk({:defmodule, _, [name, [do: body]]} = node, env, file, index) do
    env = bindings(node, env)
    module = declaration_module(name, env)
    walk(body, %{env | module: module, function: nil}, file, index)
  end

  defp walk({:__block__, _, nodes}, env, file, index) do
    {index, _env} =
      Enum.reduce(nodes, {index, env}, fn node, {acc, current} ->
        next = bindings(node, current)
        {walk(node, next, file, acc), next}
      end)

    index
  end

  defp walk({:use, _, [target | options]}, env, file, index) do
    index =
      if resolve(target, env) == Oban.Worker,
        do: %{index | workers: MapSet.put(index.workers, env.module)},
        else: index

    Enum.reduce([target | options], index, &walk(&1, env, file, &2))
  end

  defp walk({:defdelegate, meta, [head, options]}, env, file, index) do
    {name, args} = function_head(head)
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    target = resolve(Keyword.fetch!(options, :to), env)
    delegated_name = Keyword.get(options, :as, name)

    Enum.reduce((arity - defaults)..arity, index, fn callable_arity, acc ->
      env = %{env | function: {env.module, name, callable_arity}}
      acc = %{acc | definitions: MapSet.put(acc.definitions, env.function)}
      acc = reference(acc, env, file, meta, target)
      call(acc, env, file, meta, target, delegated_name, arity)
    end)
  end

  defp walk({kind, meta, [head, body]}, env, file, index)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {name, args} = function_head(head)
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))

    definitions =
      Enum.reduce(
        (arity - defaults)..arity,
        index.definitions,
        &MapSet.put(&2, {env.module, name, &1})
      )

    env = %{env | function: {env.module, name, arity}}
    index = %{index | definitions: definitions}

    index =
      Enum.reduce((arity - defaults)..arity, index, fn callable_arity, acc ->
        if callable_arity == arity do
          acc
        else
          call(
            acc,
            %{env | function: {env.module, name, callable_arity}},
            file,
            meta,
            env.module,
            name,
            arity
          )
        end
      end)

    index = walk(head, env, file, index)
    walk(body, env, file, note_worker(index, env, file, meta, name, arity))
  end

  defp walk({:|>, _, [left, {{:., _, [target, name]}, meta, args}]}, env, file, index) do
    index = call(index, env, file, meta, resolve(target, env), name, length(args) + 1)
    index = walk(target, env, file, index)

    Enum.reduce(
      [left | args],
      index,
      &walk(&1, persistence_env(env, resolve(target, env), name), file, &2)
    )
  end

  defp walk({:|>, _, [left, {name, meta, args}]}, env, file, index)
       when is_atom(name) and is_list(args) do
    index = local_call(index, env, file, meta, name, length(args) + 1)
    Enum.reduce([left | args], index, &walk(&1, env, file, &2))
  end

  defp walk({:&, _, [{:/, _, [{{:., _, [target, name]}, meta, []}, arity]}]}, env, file, index)
       when is_integer(arity) do
    index = call(index, env, file, meta, resolve(target, env), name, arity)
    walk(target, env, file, index)
  end

  defp walk({:&, _, [{:/, _, [{name, meta, _}, arity]}]}, env, file, index)
       when is_atom(name) and is_integer(arity) do
    local_call(index, env, file, meta, name, arity)
  end

  defp walk({{:., _, [kernel, :apply]}, meta, [target, name, args]}, env, file, index)
       when is_atom(name) and is_list(args) do
    index =
      if resolve(kernel, env) in [Kernel, :erlang],
        do: call(index, env, file, meta, resolve(target, env), name, length(args)),
        else: call(index, env, file, meta, resolve(kernel, env), :apply, 3)

    Enum.reduce([kernel, target | args], index, &walk(&1, env, file, &2))
  end

  defp walk({{:., _, [target, name]}, meta, args}, env, file, index)
       when is_atom(name) and is_list(args) do
    index = call(index, env, file, meta, resolve(target, env), name, length(args))
    index = note_lock(index, resolve(target, env), name, args, env)
    index = walk(target, env, file, index)

    Enum.reduce(
      args,
      index,
      &walk(&1, persistence_env(env, resolve(target, env), name), file, &2)
    )
  end

  defp walk({:__aliases__, meta, _} = ast, env, file, index) do
    reference(index, env, file, meta, resolve(ast, env))
  end

  # Supervision child specs and apply/3 can carry static MFA rather than a call.
  defp walk({:{}, meta, [target, name, args]} = ast, env, file, index)
       when is_atom(name) and is_list(args) do
    index = call(index, env, file, meta, resolve(target, env), name, length(args))
    ast |> Tuple.to_list() |> Enum.reduce(index, &walk(&1, env, file, &2))
  end

  defp walk({:apply, meta, [target, name, args]}, env, file, index)
       when is_atom(name) and is_list(args) do
    index = call(index, env, file, meta, resolve(target, env), name, length(args))
    Enum.reduce([target | args], index, &walk(&1, env, file, &2))
  end

  defp walk({name, meta, args}, env, file, index)
       when is_atom(name) and is_list(meta) and is_list(args) do
    index = local_call(index, env, file, meta, name, length(args))
    Enum.reduce(args, index, &walk(&1, env, file, &2))
  end

  defp walk(nodes, env, file, index) when is_list(nodes),
    do: Enum.reduce(nodes, index, &walk(&1, env, file, &2))

  defp walk(node, env, file, index) when is_tuple(node),
    do: node |> Tuple.to_list() |> walk(env, file, index)

  defp walk(module, env, file, index) when is_atom(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir."),
      do: reference(index, env, file, [], module),
      else: index
  end

  defp walk(_node, _env, _file, index), do: index

  # A nested declaration creates an alias for its first segment in the parent
  # scope (including qualified declarations such as Group.Leaf). Unlike ordinary
  # references, its name is nested literally, ignoring an existing segment alias.
  # Tooling only: identities come from trusted repository/synthetic AST, never runtime input.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp bindings(
         {:defmodule, _, [{:__aliases__, _, [first | _]}, _]},
         %{module: module} = env
       )
       when not is_nil(module) and is_atom(first) and first != :"Elixir" do
    %{env | aliases: Map.put(env.aliases, first, Module.concat(module, first))}
  end

  # Trusted local-source alias expansion; this parser does not accept untrusted submissions.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp bindings({:alias, _, [{{:., _, [base, :{}]}, _, names}]}, env) do
    Enum.reduce(names, env, fn name, acc ->
      module = Module.concat(resolve(base, env), resolve(name, %{env | aliases: %{}}))
      put_alias(acc, module, nil)
    end)
  end

  defp bindings({:alias, _, [target | options]}, env) do
    put_alias(env, resolve(target, env), Keyword.get(List.flatten(options), :as))
  end

  defp bindings({:import, _, [target | options]}, env) do
    %{env | imports: [{resolve(target, env), List.flatten(options)} | env.imports]}
  end

  defp bindings(_node, env), do: env

  defp put_alias(env, nil, _as), do: env

  # The alias key derives from the trusted local-source module identity.
  # sobelow_skip ["DOS.StringToAtom"]
  defp put_alias(env, module, as) do
    key =
      if as,
        do: as |> elem(2) |> List.last(),
        else: module |> Module.split() |> List.last() |> String.to_atom()

    %{env | aliases: Map.put(env.aliases, key, module)}
  end

  defp declaration_module({:__aliases__, _, [:"Elixir" | _]} = name, env),
    do: resolve(name, env)

  # Trusted local-source nested declaration, not a runtime-selected module name.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp declaration_module({:__aliases__, _, [first | rest]}, %{module: module})
       when not is_nil(module) and is_atom(first),
       do: Module.concat([module, first | rest])

  defp declaration_module(name, env), do: resolve(name, env)

  defp resolve({:__MODULE__, _, _}, env), do: env.module
  # Trusted local-source absolute alias.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp resolve({:__aliases__, _, [:"Elixir" | parts]}, _env), do: Module.concat(parts)

  # Trusted local-source __MODULE__ alias.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp resolve({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, env),
    do: Module.concat([env.module | parts])

  # Trusted local-source lexical alias environment.
  # sobelow_skip ["DOS.ModuleConcat"]
  defp resolve({:__aliases__, _, [first | rest]}, env) do
    case Map.fetch(env.aliases, first) do
      {:ok, module} -> Module.concat([module | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp resolve(module, _env) when is_atom(module), do: module
  defp resolve(_ast, _env), do: nil

  defp function_head({:when, _, [head | _]}), do: function_head(head)
  defp function_head({name, _, args}), do: {name, args || []}

  defp reference(index, env, file, meta, target) do
    entry = entry(env, file, meta) |> Map.merge(%{target: target, persistence: env.persistence})
    %{index | references: [entry | index.references]}
  end

  defp local_call(index, env, file, meta, name, arity) do
    index = call(index, env, file, meta, env.module, name, arity)

    Enum.reduce(env.imports, index, fn {module, options}, acc ->
      only = Keyword.get(options, :only)
      except = Keyword.get(options, :except, [])

      if (is_nil(only) or (is_list(only) and {name, arity} in only)) and
           {name, arity} not in except,
         do: call(acc, env, file, meta, module, name, arity),
         else: acc
    end)
  end

  defp call(index, env, file, meta, target, name, arity) do
    entry = entry(env, file, meta) |> Map.merge(%{target: target, name: name, arity: arity})
    index = %{index | calls: [entry | index.calls]}
    if async?(target, name), do: %{index | async: [entry | index.async]}, else: index
  end

  defp note_worker(index, env, file, meta, :perform, 1) do
    if MapSet.member?(index.workers, env.module) do
      entry = entry(env, file, meta) |> Map.merge(%{target: env.module, name: :perform, arity: 1})
      %{index | async: [entry | index.async]}
    else
      index
    end
  end

  defp note_worker(index, _env, _file, _meta, _name, _arity), do: index

  defp note_lock(index, :global, name, [identity | _], env)
       when name in [:trans, :set_lock, :del_lock] do
    {_ast, targets} =
      Macro.prewalk(identity, MapSet.new(), &lock_target(&1, &2, env))

    [entry | rest] = index.calls
    %{index | calls: [Map.put(entry, :lock_targets, Enum.sort(targets)) | rest]}
  end

  defp note_lock(index, _target, _name, _args, _env), do: index

  defp lock_target({:__aliases__, _, _} = node, targets, env),
    do: {node, MapSet.put(targets, resolve(node, env))}

  defp lock_target({:__MODULE__, _, _} = node, targets, env),
    do: {node, MapSet.put(targets, env.module)}

  defp lock_target(module, targets, _env) when is_atom(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir."),
      do: {module, MapSet.put(targets, module)},
      else: {module, targets}
  end

  defp lock_target(node, targets, _env), do: {node, targets}

  defp persistence_env(env, target, name) do
    persistence =
      target in [Ash, Ash.Query, Ash.Changeset] and
        name in [
          :read,
          :read!,
          :read_one,
          :read_one!,
          :get,
          :get!,
          :create,
          :create!,
          :update,
          :update!,
          :destroy,
          :destroy!,
          :bulk_create,
          :bulk_create!,
          :bulk_update,
          :bulk_update!,
          :bulk_destroy,
          :bulk_destroy!,
          :for_read,
          :for_create,
          :for_update,
          :for_destroy,
          :new
        ]

    %{env | persistence: env.persistence or persistence}
  end

  defp async?(target, name) do
    target in [Task, Task.Supervisor] or
      name in [:spawn, :spawn_link, :spawn_monitor, :start_async, :assign_async] or
      (target in [Process, :erlang, :timer] and
         name in [:send_after, :send_interval, :apply_after, :apply_interval])
  end

  defp entry(env, file, meta),
    do: %{
      module: env.module,
      function: env.function,
      file: file,
      line: Keyword.get(meta, :line, 1)
    }
end
