defmodule Lovelace.TestSupport.OnboardingKeychain do
  @moduledoc false
  use Agent

  def start_link(_opts),
    do:
      Agent.start_link(fn -> %{items: %{}, writes: 0, failure: nil, calls: []} end,
        name: __MODULE__
      )

  def put(account, value, service) do
    Agent.get_and_update(__MODULE__, fn state ->
      if state.failure do
        {{:error, state.failure}, state}
      else
        {:ok,
         %{
           state
           | items: Map.put(state.items, {account, service}, value),
             writes: state.writes + 1
         }}
      end
    end)
  end

  def get(account, service) do
    Agent.get(__MODULE__, fn state ->
      if state.failure,
        do: {:error, state.failure},
        else: Map.fetch(state.items, {account, service}) |> found()
    end)
  end

  def delete(account, service),
    do: Agent.update(__MODULE__, &%{&1 | items: Map.delete(&1.items, {account, service})})

  def writes, do: Agent.get(__MODULE__, & &1.writes)
  def fail(reason), do: Agent.update(__MODULE__, &%{&1 | failure: reason})
  def calls, do: Agent.get(__MODULE__, & &1.calls)
  def record(call), do: Agent.update(__MODULE__, &%{&1 | calls: &1.calls ++ [call]})
  defp found({:ok, value}), do: {:ok, value}
  defp found(:error), do: {:error, :not_found}
end

defmodule Lovelace.TestSupport.OnboardingGoogleTransport do
  @moduledoc false
  @behaviour Lovelace.Integrations.Google.Transport

  alias Lovelace.TestSupport.OnboardingKeychain

  @impl true
  def request(%{host: "oauth2.googleapis.com", path: "/token", method: "POST", body: body}, _opts) do
    OnboardingKeychain.record(:exchange)

    scope =
      if URI.decode_query(body)["code"] == "synthetic-calendar-code",
        do:
          "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events.readonly",
        else: "openid email https://www.googleapis.com/auth/gmail.readonly"

    json(%{
      access_token: "synthetic-onboarding-access",
      refresh_token: "synthetic-onboarding-refresh",
      token_type: "Bearer",
      expires_in: 3600,
      scope: scope
    })
  end

  def request(%{host: "openidconnect.googleapis.com", path: "/v1/userinfo", method: "GET"}, _opts) do
    OnboardingKeychain.record(:identity)

    json(%{
      sub: "synthetic-onboarding-subject",
      email: "synthetic@example.invalid",
      email_verified: true
    })
  end

  def request(
        %{
          host: "www.googleapis.com",
          path: "/calendar/v3/users/me/calendarList?" <> _,
          method: "GET"
        },
        _opts
      ) do
    OnboardingKeychain.record(:calendars)

    json(%{
      items: [
        %{id: "primary", summary: "Synthetic primary", selected: true},
        %{id: "shared@example.invalid", summary: "Synthetic shared", selected: false}
      ]
    })
  end

  def request(
        %{host: "www.googleapis.com", path: "/calendar/v3/calendars/" <> _, method: "GET"},
        _opts
      ) do
    OnboardingKeychain.record(:events)
    json(%{items: []})
  end

  def request(_request, _opts) do
    OnboardingKeychain.record(:unexpected_request)
    {:error, :transport_error}
  end

  defp json(value),
    do:
      {:ok,
       %{status: 200, headers: [{"content-type", "application/json"}], body: Jason.encode!(value)}}
end
