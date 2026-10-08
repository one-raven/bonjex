# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex do
  @moduledoc """
  DNS-SD through the system mDNS responder.

  Bonjex is a client of the host's DNS-SD daemon (mDNSResponder on macOS,
  `mdnsd` on Linux and Nerves), reached through `libdns_sd`. It does not
  implement mDNS and opens no sockets of its own. The daemon owns UDP 5353,
  probes for name conflicts, does known-answer and duplicate-question
  suppression, and keeps one cache for every client on the host.

  A connection is a process. It runs one `bonjex_port` OS process and talks to
  the daemon through it, so a slow or wedged daemon cannot block a BEAM
  scheduler.

      {:ok, conn} = Bonjex.start_link()

      :ok = Bonjex.register(conn, :web, name: "My Server", type: "_http._tcp", port: 8080)

      {:ok, ref} = Bonjex.browse(conn, "_http._tcp")
      receive do
        {:bonjex, ^ref, {:add, %{name: name, domain: domain}}} -> ...
      end

  ## Messages

  Registrations and queries report to the process that made them, their
  *owner*, as `{:bonjex, tag, event}`. For a query, `tag` is the reference
  that `browse/3`, `resolve/4` or `get_addr_info/3` returned. For a
  registration, it is `{:service, key}`.

  Every query gets:

    * `:started` each time it is sent to the daemon: when the connection is
      up, or once it comes up, and again after every reconnect.
    * `:interrupted` when the connection is lost. The daemon reports nothing
      until the query is `:started` again, so drop or age what it reported.
    * `{:error, reason}` when the daemon reports an error. The query is kept,
      and is sent again after a reconnect, until you cancel it.

  `browse/3` reports `{:add, service}` and `{:remove, service}`, where
  `service` has `:name`, `:type`, `:domain`, `:ifindex` and `:interface`.

  `resolve/4` reports `{:resolved, info}`, with `:host`, `:port`, `:txt` (see
  `Bonjex.TXT`), `:ifindex` and `:interface`, each time the SRV or TXT
  changes.

  `get_addr_info/3` reports `{:add, addr}` and `{:remove, addr}`, with
  `:host`, `:address` (an `:inet.ip_address()`), `:ttl`, `:ifindex` and
  `:interface`.

  Each of those carries `:more_coming`, true while the daemon has more answers
  queued. Use it to take a host's addresses as one batch. The flag covers the
  whole connection, not one query, so the next answer may belong to a
  different query.

  A registration gets `{:registered, %{name: name, type: type, domain:
  domain}}` once the daemon has it, and again with the new name if the daemon
  renames it after a conflict. It gets `{:error, reason}` on failure (for
  example `:name_conflict` with `rename: false`), and
  `{:error, {:address, ip, reason}}` when one of its proxy addresses is
  refused. It gets `:interrupted` when the connection is lost. Registrations
  are sent again on reconnect, and report `:registered` again.

  ## Reconnecting

  The connection owns what should exist; the port program owns nothing. Start
  a connection before the daemon is running if you like: registrations and
  queries made in the meantime wait, and are sent when it connects. Whenever
  the port exits (daemon restarted, connection dropped) the connection opens a
  new one with capped exponential backoff, forever, and replays everything.

  When an owner exits, its registrations and queries go with it.
  """

  alias Bonjex.Connection

  @type conn :: GenServer.server()
  @type key :: term()

  @doc """
  Starts a connection.

  ## Options

    * `:name` - registers the process under this name
    * `:executable` - path to `bonjex_port`. Defaults to the one built into
      this application's `priv/`.
    * `:backoff_min` - first reconnect delay in ms (default `500`)
    * `:backoff_max` - longest reconnect delay in ms (default `30_000`)
    * `:transport` - a `Bonjex.Transport` (default `Bonjex.Transport.Port`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Connection.start_link(opts)

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registers a service under `key`, or replaces the one already under it.

  Registering a key again with only a different `:txt` updates the TXT
  record in place, so the service does not disappear from the network while
  it changes. Registering it again with identical options does nothing. Any
  other change withdraws the old registration and makes a new one.

  The caller becomes the registration's owner, even if another process
  registered the key before.

  ## Options

    * `:type` - service type, such as `"_http._tcp"` (required)
    * `:port` - the service's port (required)
    * `:name` - instance name. Defaults to the host's name.
    * `:txt` - a map or keyword list; see `Bonjex.TXT.normalize/1`
    * `:subtypes` - e.g. `["_printer"]`
    * `:domain` - defaults to the daemon's default domain, normally `local.`
    * `:host` - a name to advertise the service on in place of this host,
      for a proxy registration (e.g. `"device-1.local"`). A name with no dot
      gets `.local` appended.
    * `:addresses` - the A and AAAA records to publish for `:host`, as
      `:inet.ip_address()` tuples or strings. Ignored without `:host`.
      Services sharing a host share these records.
    * `:ttl` - TTL for those address records in seconds (default `120`)
    * `:ifindex` - register on this interface only (default `0`, all)
    * `:rename` - let the daemon rename the service on a conflict (default
      `true`). With `false`, a conflict is `{:error, :name_conflict}`.
  """
  @spec register(conn(), key(), keyword()) :: :ok
  def register(conn, key, opts) do
    GenServer.call(conn, {:register, key, Connection.service_spec(opts), self()})
  end

  @doc """
  Withdraws the registration under `key`. Unknown keys are a no-op.

  Drops any of its messages already in the caller's mailbox.
  """
  @spec unregister(conn(), key()) :: :ok
  def unregister(conn, key) do
    :ok = GenServer.call(conn, {:unregister, key})
    flush({:service, key})
  end

  @doc """
  Browses for services of `type`, such as `"_http._tcp"`, until cancelled.

  ## Options

    * `:subtype` - browse only this subtype, e.g. `"_printer"`
    * `:domain` - defaults to the daemon's browse domains
    * `:ifindex` - browse on this interface only (default `0`, all)
  """
  @spec browse(conn(), String.t(), keyword()) :: {:ok, reference()}
  def browse(conn, type, opts \\ []) do
    opts = Keyword.validate!(opts, subtype: nil, domain: nil, ifindex: 0)

    query(conn, %{
      kind: :browse,
      type: if(opts[:subtype], do: type <> "," <> opts[:subtype], else: type),
      domain: opts[:domain],
      ifindex: opts[:ifindex]
    })
  end

  @doc """
  Resolves the service instance `name` of `type` to its host, port and TXT
  record, reporting every change until cancelled.

  ## Options

    * `:domain` - default `"local."`
    * `:ifindex` - default `0`, any. Passing the `:ifindex` from the browse
      result that found the instance avoids asking on every interface.
  """
  @spec resolve(conn(), String.t(), String.t(), keyword()) :: {:ok, reference()}
  def resolve(conn, name, type, opts \\ []) do
    opts = Keyword.validate!(opts, domain: "local.", ifindex: 0)

    query(conn, %{
      kind: :resolve,
      name: name,
      type: type,
      domain: opts[:domain],
      ifindex: opts[:ifindex]
    })
  end

  @doc """
  Looks up the addresses of `host`, such as a `:host` from `resolve/4`,
  reporting every change until cancelled.

  ## Options

    * `:families` - any of `[:inet, :inet6]` (default both)
    * `:ifindex` - default `0`, any
  """
  @spec get_addr_info(conn(), String.t(), keyword()) :: {:ok, reference()}
  def get_addr_info(conn, host, opts \\ []) do
    opts = Keyword.validate!(opts, families: [:inet, :inet6], ifindex: 0)
    families = opts[:families]

    if families == [] or Enum.any?(families, &(&1 not in [:inet, :inet6])) do
      raise ArgumentError, "invalid :families #{inspect(families)}"
    end

    query(conn, %{kind: :addrinfo, host: host, families: families, ifindex: opts[:ifindex]})
  end

  @doc """
  Stops a query. Unknown references are a no-op.

  Drops any of its messages already in the caller's mailbox.
  """
  @spec cancel(conn(), reference()) :: :ok
  def cancel(conn, ref) when is_reference(ref) do
    :ok = GenServer.call(conn, {:cancel, ref})
    flush(ref)
  end

  @doc "True while the connection is connected to the daemon."
  @spec connected?(conn()) :: boolean()
  def connected?(conn), do: GenServer.call(conn, :connected?)

  @doc "Keys registered on this connection, whether or not the daemon has them yet."
  @spec registered(conn()) :: [key()]
  def registered(conn), do: GenServer.call(conn, :registered)

  defp query(conn, spec) do
    if not is_integer(spec.ifindex) or spec.ifindex < 0 do
      raise ArgumentError, "invalid :ifindex #{inspect(spec.ifindex)}"
    end

    GenServer.call(conn, {:query, spec, self()})
  end

  defp flush(tag) do
    receive do
      {:bonjex, ^tag, _} -> flush(tag)
    after
      0 -> :ok
    end
  end
end
