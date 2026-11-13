defmodule Monolith.Mail.Provider do
  @moduledoc """
  Application-owned contract for bounded, read-only Gmail observations.

  Adapters return the existing lean payload maps, not cache records or a second
  domain model. Tokens, queries, provider identifiers and payloads are private;
  failures contain only the finite safe atoms below, never a response or exception.
  OAuth, credential storage and revocation belong to `Monolith.Google.OAuthProvider`,
  not this replay-safe read contract.

  Each call has one bounded deadline (Google defaults to 15 seconds, at most 30).
  Inbox/search return at most 20 summaries and an opaque continuation token of at
  most 4096 bytes. A page is not a complete mailbox or an unread-total estimate;
  callers explicitly request another page. Queries are at most 4096 UTF-8 bytes.
  Summaries contain plain, untrusted text; oversized or invalid headers/snippets
  become empty strings (8192-byte field limit). A failed metadata read fails the
  page, not a partial successful page.

  Threads contain 1..100 messages. Each message is bounded to MIME depth 10,
  100 parts, 2 MiB encoded text and 256 KiB decoded text. Limit violations fail
  rather than silently presenting a partial conversation. Optional malformed or
  unsupported attachment metadata may be omitted; metadata is not a promise that
  a file is downloadable. Attachment bytes are fetched only explicitly and are
  capped at 5 MiB. Callers authorize attachment IDs against the account-scoped
  cached conversation; adapters do not make account or workspace policy decisions.

  Unread totals are inbox conversation counts, not message counts: `total` is the
  provider's unread-inbox total, while `recent` counts fully paged distinct unread
  inbox conversations received in a fixed preceding 24-hour UTC window. At most
  ten pages of 500 IDs share the call deadline. Incomplete or looping pagination
  fails; it never produces an estimate or a false zero. The two observations are
  not an atomic mailbox snapshot.

  Results describe a provider observation, with no cache freshness guarantee.
  The application owns observation timestamps, retention and generation fences.
  Read errors may be retried under application admission/cooldown policy, without
  mutating the mailbox; they do not prove a credential has been revoked.
  """

  @type access_token :: binary()
  @type provider_id :: binary()
  @type page_token :: binary() | nil
  @type error ::
          :timeout
          | :response_too_large
          | :transport_error
          | :invalid_configuration
          | :invalid_request
          | :invalid_response
          | :invalid_grant
          | :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :provider_error
          | :locked
  @type failure :: {:error, error()}
  @type summary :: %{
          id: provider_id(),
          subject: binary(),
          from: binary(),
          snippet: binary(),
          unread: boolean(),
          date: binary()
        }
  @type page :: %{threads: [summary()], next_page_token: page_token()}
  @type attachment_metadata :: %{
          attachment_id: provider_id(),
          filename: binary(),
          mime_type: binary(),
          size: non_neg_integer()
        }
  @type message :: %{
          id: provider_id(),
          from: binary(),
          to: binary(),
          date: binary(),
          subject: binary(),
          text: binary(),
          attachments: [attachment_metadata()]
        }
  @type thread :: %{id: provider_id(), messages: [message()]}
  @type unread :: %{total: non_neg_integer(), recent: non_neg_integer()}

  @callback inbox(access_token(), page_token()) :: {:ok, page()} | failure()
  @callback search(access_token(), binary(), page_token()) :: {:ok, page()} | failure()
  @callback inbox_unread(access_token()) :: {:ok, unread()} | failure()
  @callback thread(access_token(), provider_id()) :: {:ok, thread()} | failure()
  @callback attachment(access_token(), provider_id(), provider_id()) ::
              {:ok, binary()} | failure()
end
