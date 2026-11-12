defmodule Monolith.ArchitectureCheckTest do
  use ExUnit.Case, async: true

  alias Monolith.Architecture.{Check, Source}
  alias Monolith.Example
  alias Monolith.Example.Group.Leaf
  alias Monolith.Example.{Inner, Sibling}
  alias Monolith.Explicit

  test "core/web references resolve renamed aliases and reject configuration discovery" do
    violations =
      check("""
      defmodule Monolith.GitHub.Auth do
        alias MonolithWeb.Endpoint, as: Browser
        def callback, do: Application.get_env(:monolith, Browser)
      end
      """)

    assert_rule(violations, :core_to_web)
    assert Enum.all?(violations, &(&1.file == "fixture.ex" and is_integer(&1.line)))
  end

  test "nested application modules retain their core namespace" do
    violations =
      check("""
      defmodule Monolith.Example do
        defmodule Inner do
          def callback, do: MonolithWeb.Endpoint.url()
        end
      end
      """)

    assert_rule(violations, :core_to_web)
    assert Enum.any?(violations, &String.contains?(&1.message, "Monolith.Example.Inner"))
  end

  test "nested integration modules retain their adapter namespace" do
    violations =
      check("""
      defmodule Monolith.Integrations.Example do
        defmodule Transport do
          def fetch, do: Monolith.GitHub.Operations.poll("id")
        end
      end
      """)

    assert_rule(violations, :adapter_to_orchestration)

    assert Enum.any?(
             violations,
             &String.contains?(&1.message, "Monolith.Integrations.Example.Transport")
           )
  end

  test "nested declarations install sibling aliases without reusing an existing name alias" do
    source = """
    defmodule Monolith.Example do
      alias Monolith.SharedHelper, as: Inner
      defmodule Inner do
        def value, do: :ok
      end
      defmodule Group.Leaf do
        def value, do: :ok
      end
      defmodule Sibling do
        def value, do: {Inner.value(), Group.Leaf.value()}
      end
      def value, do: Sibling.value()
      defmodule Elixir.Monolith.Explicit do
        def value, do: :ok
      end
    end
    """

    assert [] == check(source)
    index = Source.parse!([{"nested.ex", source}])

    for module <- [Inner, Leaf, Sibling, Explicit] do
      assert MapSet.member?(index.definitions, {module, :value, 0})
    end

    for target <- [Inner, Leaf] do
      assert Enum.any?(index.calls, fn call ->
               call.function == {Sibling, :value, 0} and call.target == target
             end)
    end

    assert Enum.any?(index.calls, fn call ->
             call.function == {Example, :value, 0} and call.target == Sibling
           end)
  end

  test "composition exceptions are exact edges, not namespace exemptions" do
    assert [] ==
             check("""
             defmodule Monolith.Application do
               def children, do: [MonolithWeb.Endpoint, MonolithWeb.Telemetry]
             end
             defmodule Monolith.Security.Bootstrap do
               def port, do: Application.fetch_env!(:monolith, MonolithWeb.Endpoint)
             end
             """)

    assert_rule(
      check("""
      defmodule Monolith.Application do
        def forbidden, do: MonolithWeb.HomeLive.mount(nil, nil, nil)
      end
      defmodule Monolith.Security.Other do
        def forbidden, do: MonolithWeb.Endpoint.config(:url)
      end
      """),
      :core_to_web
    )
  end

  test "adapters cannot discover configuration through orchestration aliases" do
    assert_rule(
      check("""
      defmodule Monolith.Integrations.GitHub.Transport do
        alias Monolith.GitHub.{Auth, Operations}
        def callback, do: Auth.callback_uri()
        def snapshot, do: Operations.poll("id")
      end
      """),
      :adapter_to_orchestration
    )
  end

  test "UI cannot escape into provider work through a helper and local function" do
    violations =
      check("""
      defmodule MonolithWeb.ProviderHelper do
        def fetch(id), do: perform(id)
        defp perform(id), do: Monolith.Integrations.Google.thread(id)
      end
      defmodule MonolithWeb.ExampleLive do
        alias MonolithWeb.ProviderHelper, as: Helper
        def handle_event(id), do: Helper.fetch(id)
      end
      """)

    assert_rule(violations, :ui_provider_work)

    assert Enum.any?(
             violations,
             &String.contains?(
               &1.message,
               "ExampleLive.handle_event/1 -> MonolithWeb.ProviderHelper.fetch/1"
             )
           )
  end

  test "UI reachability follows imports, pipelines, captures, defaults, delegates and static apply" do
    violations =
      check(~S'''
      defmodule Monolith.ProviderHelper do
        def fetch(id, opts \\ []), do: Monolith.Integrations.GitHub.snapshot(id, opts)
      end
      defmodule MonolithWeb.ExampleLive do
        import Monolith.ProviderHelper, only: [fetch: 1]
        def piped(id), do: id |> fetch()
        def captured, do: &Monolith.ProviderHelper.fetch/1
        def applied(id), do: apply(Monolith.ProviderHelper, :fetch, [id])
        def remote_applied(id), do: Kernel.apply(Monolith.ProviderHelper, :fetch, [id])
        defdelegate delegated(id), to: Monolith.ProviderHelper, as: :fetch
      end
      ''')

    for function <- ["piped/1", "captured/0", "applied/1", "remote_applied/1", "delegated/1"] do
      assert Enum.any?(
               violations,
               &(&1.rule == :ui_provider_work and String.contains?(&1.message, function))
             )
    end
  end

  test "guarded helpers cannot hide provider work behind local captures and nested modules" do
    violations =
      check("""
      defmodule Monolith.ReadHelper do
        alias Monolith.Integrations.Google, as: Provider
        defmodule Transport do
          def fetch(id) when is_binary(id), do: Provider.thread(id)
        end
        def fetch(ids) when is_list(ids), do: Enum.map(ids, &read/1)
        defp read(id), do: __MODULE__.Transport.fetch(id)
      end
      defmodule MonolithWeb.ExampleLive do
        alias Monolith.ReadHelper, as: Helper
        def load(ids), do: Helper.fetch(ids)
      end
      """)

    assert Enum.any?(violations, fn violation ->
             violation.rule == :ui_provider_work and
               violation.message ==
                 "UI provider path: MonolithWeb.ExampleLive.load/1 -> " <>
                   "Monolith.ReadHelper.fetch/1 -> Monolith.ReadHelper.read/1 -> " <>
                   "Monolith.ReadHelper.Transport.fetch/1 -> " <>
                   "Monolith.Integrations.Google.thread/1"
           end)
  end

  test "literal module atoms cannot hide orchestration configuration from an adapter" do
    violations =
      check("""
      defmodule Monolith.Integrations.GitHub.Transport do
        def configuration do
          Application.fetch_env!(:monolith, :"Elixir.Monolith.GitHub.Auth")
        end
      end
      """)

    assert Enum.any?(violations, fn violation ->
             violation.rule == :adapter_to_orchestration and
               violation.message ==
                 "adapter Elixir.Monolith.Integrations.GitHub.Transport depends on " <>
                   "orchestration Elixir.Monolith.GitHub.Auth"
           end)
  end

  test "non-Kernel apply follows its own implementation rather than executing its MFA arguments" do
    violations =
      check("""
      defmodule Monolith.CallSpec do
        def apply(module, function, args), do: %{module: module, function: function, args: args}
        def project(id), do: %{id: id}
      end
      defmodule Monolith.ReadHelper do
        def fetch(id), do: Monolith.Integrations.Google.thread(id)
        def apply(_resource, _field, [id]), do: __MODULE__.fetch(id)
      end
      defmodule MonolithWeb.ExampleLive do
        alias Monolith.CallSpec, as: Spec
        alias Monolith.ReadHelper, as: Helper
        def describe(id), do: Spec.apply(Helper, :fetch, [id])
        def load(id), do: Helper.apply(Spec, :project, [id])
      end
      """)

    assert [violation] = violations
    assert violation.rule == :ui_provider_work

    assert violation.message ==
             "UI provider path: MonolithWeb.ExampleLive.load/1 -> " <>
               "Monolith.ReadHelper.apply/3 -> Monolith.ReadHelper.fetch/1 -> " <>
               "Monolith.Integrations.Google.thread/1"
  end

  test "a pure helper projection is not tainted by an unrelated provider function" do
    assert [] ==
             check("""
             defmodule Monolith.SharedHelper do
               def project(value), do: %{count: length(value)}
               def provider(id), do: Monolith.Integrations.Google.thread(id)
             end
             defmodule MonolithWeb.ExampleLive do
               def render(values), do: Monolith.SharedHelper.project(values)
             end
             """)
  end

  test "an application helper is not a transitive provider escape" do
    assert_rule(
      check("""
      defmodule Monolith.ReadHelper do
        def load(id), do: Monolith.Integrations.Google.thread(id)
      end
      defmodule MonolithWeb.ExampleLive do
        def load(id), do: Monolith.ReadHelper.load(id)
      end
      """),
      :ui_provider_work
    )
  end

  test "Ash domains, resources, contracts and local credential status are allowed" do
    assert [] ==
             check("""
             defmodule Monolith.Mail do
               use Ash.Domain
               resources do
                 resource Monolith.Mail.Account
               end
             end
             defmodule Monolith.Mail.Provider do
               @callback page(binary()) :: {:ok, map()}
             end
             defmodule Monolith.Integrations.Google do
               @behaviour Monolith.Mail.Provider
               def page(id), do: {:ok, %{id: id}}
             end
             defmodule Monolith.Calendar.Projection do
               alias Monolith.Mail.Account
               def account_type, do: Account
             end
             defmodule MonolithWeb.ExampleLive do
               def load, do: Monolith.Mail.accounts(actor: %{role: :local_owner})
               def local_status, do: Monolith.Integrations.Google.ClientCredentials.status()
             end
             """)
  end

  test "cross-domain persistence is rejected without banning resource references" do
    assert_rule(
      check("""
      defmodule Monolith.Onboarding.CalendarSetup do
        alias Monolith.Calendar.State, as: CalendarState
        def load, do: CalendarState |> Ash.Query.for_read(:read) |> Ash.read!()
      end
      """),
      :private_domain_persistence
    )

    assert [] ==
             check("""
             defmodule Monolith.Calendar.Operations do
               def load, do: Monolith.Calendar.State |> Ash.Query.for_read(:read) |> Ash.read!()
             end
             defmodule Monolith.Google.Access do
               def account, do: Ash.get(Monolith.Mail.Account, "synthetic-id")
               def transact(fun), do: Ash.transact([Monolith.Mail.Account, Monolith.Mail.WorkspaceAccount], fun)
             end
             """)
  end

  test "foreign private capabilities and borrowed lock identities are rejected" do
    assert_rule(
      check("""
      defmodule Monolith.Calendar.Operations do
        def token(id), do: Monolith.Mail.Operations.access_token(id)
      end
      """),
      :private_domain_capability
    )

    assert_rule(
      check("""
      defmodule Monolith.GitHub.ClientCredentials do
        alias Monolith.GitHub.Operations
        def change(fun), do: :global.trans({{Operations, :state}, self()}, fun)
      end
      """),
      :private_lock_identity
    )
  end

  test "the coordination owner may call orchestration inside its own lock" do
    assert [] ==
             check("""
             defmodule Monolith.GitHub.Coordination do
               def change do
                 :global.trans({{__MODULE__, :state}, self()}, fn ->
                   Monolith.GitHub.Operations.commit()
                 end)
               end
             end
             """)
  end

  test "web callers cannot bypass private persistence or private domain capabilities" do
    violations =
      check("""
      defmodule MonolithWeb.ExampleLive do
        def private_state, do: Ash.read!(Monolith.Calendar.State)
        def private_call, do: Monolith.Mail.Operations.account_page("id")
      end
      """)

    assert_rule(violations, :private_domain_persistence)
    assert_rule(violations, :private_domain_capability)
  end

  test "comments and string contents cannot fabricate dependency findings" do
    assert [] ==
             check(~S'''
             defmodule Monolith.Example do
               # MonolithWeb.Endpoint.config(:url)
               def example, do: "MonolithWeb.Endpoint and Task.async are documentation"
             end
             ''')
  end

  test "syntax errors fail closed and results have deterministic order" do
    assert_raise TokenMissingError, fn -> check("defmodule Monolith.Bad do") end

    left =
      {"b.ex", "defmodule Monolith.B do\n def bad, do: MonolithWeb.Endpoint.config(:url)\nend"}

    right =
      {"a.ex", "defmodule Monolith.A do\n def bad, do: MonolithWeb.Endpoint.config(:url)\nend"}

    assert Check.check([left, right]) == Check.check([right, left])
  end

  test "the async inventory indexes aliases, supervision MFAs, timers and worker entries" do
    index =
      Source.parse!([
        {"inventory.ex",
         """
         defmodule Monolith.Inventory do
           use Oban.Worker, queue: :synthetic
           alias Task, as: Bounded
           def run, do: Bounded.async(fn -> :ok end)
           def child, do: {Task, :start_link, [fn -> :ok end]}
           def timer, do: Process.send_after(self(), :expire, 100)
           def ui(socket), do: Phoenix.LiveView.start_async(socket, :read, fn -> :ok end)
           def perform(_job), do: :ok
         end
         """}
      ])

    for name <- [:async, :start_link, :send_after, :start_async, :perform] do
      assert Enum.any?(index.async, &(&1.name == name and &1.file == "inventory.ex"))
    end
  end

  defp check(source), do: Check.check([{"fixture.ex", source}])

  defp assert_rule(violations, rule) do
    assert Enum.any?(violations, &(&1.rule == rule)), inspect(violations)
  end
end
