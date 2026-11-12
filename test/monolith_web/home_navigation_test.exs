defmodule MonolithWeb.HomeNavigationTest do
  use ExUnit.Case, async: true

  alias MonolithWeb.HomeNavigation

  test "current URL reads only the parsed destination, not conflicting page or mail projections" do
    {:ok, destination} = HomeNavigation.destination(:settings, %{})

    socket = %{
      assigns: %{
        destination: destination,
        home: true,
        settings: false,
        scenes: true,
        connections: true,
        connection_view: :github,
        selected: %{id: Ash.UUID.generate()},
        mail: %{account_id: Ash.UUID.generate()}
      }
    }

    assert HomeNavigation.current(socket) == "/settings"
  end

  test "parsed destinations generate the existing deep-link paths and query context" do
    workspace = Ash.UUID.generate()
    account = Ash.UUID.generate()

    params = %{
      "workspace_id" => workspace,
      "account_id" => account,
      "thread_id" => "synthetic-thread",
      "q" => "from:sender@example.test",
      "page_token" => "synthetic-page"
    }

    for {action, path} <- [
          {:index, "/"},
          {:workspaces, "/workspaces"},
          {:settings, "/settings"},
          {:connections, "/connections"},
          {:workspace, "/workspaces/#{workspace}"},
          {:integration_add, "/workspaces/#{workspace}/integrations"}
        ] do
      assert {:ok, destination} = HomeNavigation.destination(action, params)
      assert HomeNavigation.path(destination) == path
    end

    assert {:ok, thread} = HomeNavigation.destination(:workspace_thread, params)
    uri = URI.parse(HomeNavigation.path(thread))

    assert uri.path ==
             "/workspaces/#{workspace}/accounts/#{account}/mail/threads/synthetic-thread"

    assert URI.decode_query(uri.query) == %{
             "q" => params["q"],
             "page_token" => params["page_token"]
           }

    assert {:ok, scenes} =
             HomeNavigation.destination(:scenes, %{"page" => "2", "attempt_page" => "3"})

    assert HomeNavigation.path(scenes) == "/scenes?page=2&attempt_page=3"
    assert {:ok, provider} = HomeNavigation.destination(:connection, %{"provider" => "calendar"})
    assert HomeNavigation.path(provider) == "/connections/calendar"
  end

  test "destination changes replace every derived page flag in one projection" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    socket = HomeNavigation.put(socket, :connection, %{"provider" => "github"})
    assert socket.assigns.connections
    assert socket.assigns.connection_view == :github
    refute socket.assigns.home || socket.assigns.settings || socket.assigns.scenes

    socket = HomeNavigation.put(socket, :settings)
    assert socket.assigns.settings
    assert socket.assigns.connection_view == :index
    refute socket.assigns.home || socket.assigns.connections || socket.assigns.scenes
    assert HomeNavigation.current(socket) == "/settings"
  end
end
