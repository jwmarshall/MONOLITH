defmodule LovelaceWeb.MailAttachmentControllerTest do
  use LovelaceWeb.ConnCase, async: false

  alias Lovelace.Mail
  alias Lovelace.Mail.Connections

  @owner %{role: :local_owner}

  setup %{conn: conn} do
    {:ok, _pid} = Lovelace.TestMail.start()
    previous_provider = Application.get_env(:lovelace, :gmail_provider)
    previous_vault = Application.get_env(:lovelace, :gmail_vault)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      if previous_provider,
        do: Application.put_env(:lovelace, :gmail_provider, previous_provider),
        else: Application.delete_env(:lovelace, :gmail_provider)

      if previous_vault,
        do: Application.put_env(:lovelace, :gmail_vault, previous_vault),
        else: Application.delete_env(:lovelace, :gmail_vault)
    end)

    workspace = Lovelace.Workspaces.create_workspace!("Attachment controller", actor: @owner)

    {:ok, account} =
      Connections.accept(
        workspace.id,
        %{subject: "attachment-subject", email: "attachment@example.invalid"},
        "attachment-token"
      )

    assert %{error: nil} = Mail.account_thread!(account.id, "same-id", actor: @owner)

    %{conn: conn, account: account}
  end

  test "attachment route requires owner unlock and returns safe explicit downloads", context do
    path = attachment_path(context.account.id) <> "?download=1"
    assert get(context.conn, path).status == 302

    conn = context.conn |> authenticate_owner() |> get(path)
    assert conn.status == 200
    assert conn.resp_body == "synthetic file"
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="note.txt")]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert {:attachment, "access:attachment-token", "message", "part-a"} in Lovelace.TestMail.calls()
  end

  test "unlisted attachment IDs do not trigger provider fetch", context do
    path = attachment_path(context.account.id, "not-listed")
    conn = context.conn |> authenticate_owner() |> get(path)
    assert conn.status == 404
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:attachment, _, _, _}, &1))
  end

  defp attachment_path(account_id, attachment_id \\ "part-a") do
    "/accounts/#{account_id}/mail/threads/same-id/messages/message/attachments/#{attachment_id}"
  end
end
