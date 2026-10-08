# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.Connection do
  @moduledoc false
  # The process behind a `Bonjex` connection. See `Bonjex` for the contract.
  #
  # `services` and `queries` are what should exist. Everything under `wire`,
  # `live` and `addrs` describes what the current port has been asked for, and
  # is thrown away whenever the port goes. Refs on the wire are fresh integers
  # per request, so a late reply for something since removed matches nothing.

  use GenServer
  require Logger

  alias Bonjex.{Protocol, TXT}

  @backoff_min 500
  @backoff_max 30_000
  @default_ttl 120

  defstruct transport: nil,
            transport_opts: [],
            handle: nil,
            up?: false,
            backoff: @backoff_min,
            backoff_min: @backoff_min,
            backoff_max: @backoff_max,
            warned?: false,
            services: %{},
            queries: %{},
            wire: %{},
            live: %{},
            addrs: %{},
            next: 1

  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # --- Validation, run in the caller so a bad option crashes the caller ---

  @service_opts [
    :type,
    :port,
    name: nil,
    txt: [],
    subtypes: [],
    domain: nil,
    host: nil,
    addresses: [],
    ttl: @default_ttl,
    ifindex: 0,
    rename: true
  ]

  @doc false
  def service_spec(opts) do
    opts = Keyword.validate!(opts, @service_opts)

    type = opts[:type] || raise ArgumentError, "missing :type"
    port = opts[:port] || raise ArgumentError, "missing :port"

    unless is_integer(port) and port in 0..65_535 do
      raise ArgumentError, "invalid :port #{inspect(port)}"
    end

    unless is_integer(opts[:ifindex]) and opts[:ifindex] >= 0 do
      raise ArgumentError, "invalid :ifindex #{inspect(opts[:ifindex])}"
    end

    host = opts[:host] && fqdn(opts[:host])

    %{
      name: opts[:name],
      type: type,
      subtypes: opts[:subtypes] |> Enum.uniq() |> Enum.sort(),
      domain: opts[:domain],
      port: port,
      host: host,
      addresses: if(host, do: opts[:addresses] |> Enum.map(&ip!/1) |> Enum.uniq(), else: []),
      ttl: opts[:ttl],
      ifindex: opts[:ifindex],
      rename: opts[:rename],
      txt: TXT.normalize(opts[:txt])
    }
  end

  defp fqdn(host) do
    host = String.trim_trailing(host, ".")
    host = if String.contains?(host, "."), do: host, else: host <> ".local"
    host <> "."
  end

  defp ip!(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> raise ArgumentError, "invalid address #{inspect(ip)}"
      _ -> ip
    end
  end

  defp ip!(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, ip} -> ip
      {:error, _} -> raise ArgumentError, "invalid address #{inspect(ip)}"
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    backoff_min = Keyword.get(opts, :backoff_min, @backoff_min)

    state = %__MODULE__{
      transport: Keyword.get(opts, :transport, Bonjex.Transport.Port),
      transport_opts: opts,
      backoff: backoff_min,
      backoff_min: backoff_min,
      backoff_max: Keyword.get(opts, :backoff_max, @backoff_max)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl true
  def handle_call({:register, key, spec, owner}, _from, state) do
    state =
      case Map.fetch(state.services, key) do
        {:ok, %{spec: ^spec, owner: ^owner}} ->
          state

        {:ok, %{spec: previous} = svc} ->
          state = put_in(state.services[key], %{svc | spec: spec} |> watch(owner))
          if state.up?, do: change(state, key, previous, spec), else: state

        :error ->
          state = put_in(state.services[key], watch(%{spec: spec}, owner))
          if state.up?, do: push(state, key), else: state
      end

    {:reply, :ok, state}
  end

  def handle_call({:unregister, key}, _from, state) do
    {:reply, :ok, drop_service(state, key)}
  end

  def handle_call({:query, spec, owner}, _from, state) do
    ref = make_ref()
    state = put_in(state.queries[ref], watch(%{spec: spec}, owner))
    state = if state.up?, do: start_query(state, ref), else: state
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:cancel, ref}, _from, state) do
    {:reply, :ok, drop_query(state, ref)}
  end

  def handle_call(:connected?, _from, state), do: {:reply, state.up?, state}
  def handle_call(:registered, _from, state), do: {:reply, Map.keys(state.services), state}

  @impl true
  def handle_info({handle, {:data, data}}, %{handle: handle} = state) do
    {:noreply, handle_reply(Protocol.decode(data), state)}
  end

  def handle_info({handle, {:exit_status, status}}, %{handle: handle} = state) do
    state =
      if state.up? do
        Logger.debug("Bonjex: connection to the responder lost (port exit #{status})")

        for {key, svc} <- state.services, do: notify(svc.owner, {:service, key}, :interrupted)
        for {ref, q} <- state.queries, do: notify(q.owner, ref, :interrupted)
        state
      else
        state
      end

    state = %{state | handle: nil, up?: false, wire: %{}, live: %{}, addrs: %{}}
    {:noreply, schedule_retry(state)}
  end

  def handle_info(:open, state), do: {:noreply, open(state)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.services, state, fn
        {key, %{monitor: ^monitor}}, acc -> drop_service(acc, key)
        _, acc -> acc
      end)

    state =
      Enum.reduce(state.queries, state, fn
        {ref, %{monitor: ^monitor}}, acc -> drop_query(acc, ref)
        _, acc -> acc
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- The port ---

  defp open(state) do
    case state.transport.open(state.transport_opts) do
      {:ok, handle} ->
        %{state | handle: handle, up?: false}

      {:error, reason} ->
        unless state.warned? do
          Logger.warning("Bonjex: cannot start the port program (#{inspect(reason)}); retrying")
        end

        schedule_retry(%{state | warned?: true})
    end
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :open, state.backoff)
    %{state | backoff: min(state.backoff * 2, state.backoff_max)}
  end

  defp handle_reply(:up, state) do
    Logger.debug("Bonjex: connected to the responder")
    state = %{state | up?: true, backoff: state.backoff_min, warned?: false}
    state = Enum.reduce(Map.keys(state.services), state, &push(&2, &1))
    Enum.reduce(Map.keys(state.queries), state, &start_query(&2, &1))
  end

  # Overwhelmingly the daemon not being up yet. The port exits next.
  defp handle_reply({:fatal, reason}, state) do
    Logger.debug("Bonjex: responder unavailable (#{inspect(reason)})")
    state
  end

  defp handle_reply({:registered, wref, info}, state) do
    with {:service, key} <- state.wire[wref], %{owner: owner} <- state.services[key] do
      notify(owner, {:service, key}, {:registered, info})
    end

    state
  end

  defp handle_reply({:ok, _wref}, state), do: state

  defp handle_reply({:error, wref, reason}, state) do
    case state.wire[wref] do
      {:service, key} ->
        notify(state.services[key].owner, {:service, key}, {:error, reason})

      {:query, ref} ->
        notify(state.queries[ref].owner, ref, {:error, reason})

      {:addr, {_host, ip} = akey} ->
        for key <- state.addrs[akey].owners do
          notify(state.services[key].owner, {:service, key}, {:error, {:address, ip, reason}})
        end

      nil ->
        :ok
    end

    state
  end

  defp handle_reply({:event, wref, event}, state) do
    with {:query, ref} <- state.wire[wref], %{owner: owner} <- state.queries[ref] do
      notify(owner, ref, event)
    end

    state
  end

  defp handle_reply(:unknown, state), do: state

  defp send_frame(state, fields) do
    state.transport.command(state.handle, Protocol.encode(fields))
  end

  defp take_ref(state, owner) do
    wref = Integer.to_string(state.next)
    {wref, %{state | next: state.next + 1, wire: Map.put(state.wire, wref, owner)}}
  end

  defp forget(state, wref) do
    send_frame(state, ["remove", wref])
    %{state | wire: Map.delete(state.wire, wref)}
  end

  # --- Services ---

  defp change(state, key, previous, spec) do
    cond do
      previous == spec -> state
      Map.delete(previous, :txt) == Map.delete(spec, :txt) -> update_txt(state, key, spec)
      true -> push(state, key)
    end
  end

  defp update_txt(state, key, spec) do
    case state.live[{:service, key}] do
      nil ->
        push(state, key)

      wref ->
        send_frame(state, ["update", wref | txt_fields(spec.txt)])
        state
    end
  end

  # One service registration, plus a claim on one address record per address
  # when the service names a proxy host.
  defp push(state, key) do
    state = pull(state, key)
    spec = state.services[key].spec

    {wref, state} = take_ref(state, {:service, key})

    send_frame(state, [
      "register",
      wref,
      spec.ifindex,
      if(spec.rename, do: "", else: "n"),
      spec.name || "",
      Enum.join([spec.type | spec.subtypes], ","),
      spec.domain || "",
      spec.host || "",
      spec.port | txt_fields(spec.txt)
    ])

    state = put_in(state.live[{:service, key}], wref)
    Enum.reduce(spec.addresses, state, &claim_addr(&2, key, spec, &1))
  end

  defp txt_fields(txt) do
    Enum.map(txt, fn
      {k, true} -> k
      {k, v} -> k <> "=" <> Base.encode16(v, case: :lower)
    end)
  end

  # Address records are keyed on {host, ip} and shared by every service that
  # names them, because registering the same unique record twice on one
  # connection would have the daemon arbitrate a name against itself.
  defp claim_addr(state, key, spec, ip) do
    akey = {spec.host, ip}

    case Map.fetch(state.addrs, akey) do
      {:ok, rec} ->
        put_in(state.addrs[akey], %{rec | owners: MapSet.put(rec.owners, key)})

      :error ->
        {wref, state} = take_ref(state, {:addr, akey})
        send_frame(state, ["record", wref, spec.ifindex, spec.host, :inet.ntoa(ip), spec.ttl])
        put_in(state.addrs[akey], %{ref: wref, owners: MapSet.new([key])})
    end
  end

  # Withdraws the key's registration and its share of each address record. A
  # record goes once nothing holds it.
  defp pull(state, key) do
    state =
      case Map.pop(state.live, {:service, key}) do
        {nil, _} -> state
        {wref, live} -> forget(%{state | live: live}, wref)
      end

    Enum.reduce(state.addrs, state, fn {akey, rec}, acc ->
      cond do
        not MapSet.member?(rec.owners, key) ->
          acc

        MapSet.size(rec.owners) == 1 ->
          forget(%{acc | addrs: Map.delete(acc.addrs, akey)}, rec.ref)

        true ->
          put_in(acc.addrs[akey], %{rec | owners: MapSet.delete(rec.owners, key)})
      end
    end)
  end

  defp drop_service(state, key) do
    case Map.pop(state.services, key) do
      {nil, _} ->
        state

      {svc, services} ->
        Process.demonitor(svc.monitor, [:flush])
        state = if state.up?, do: pull(state, key), else: state
        %{state | services: services}
    end
  end

  # --- Queries ---

  defp start_query(state, ref) do
    %{spec: spec, owner: owner} = state.queries[ref]
    {wref, state} = take_ref(state, {:query, ref})
    notify(owner, ref, :started)

    send_frame(state, query_frame(wref, spec))
    put_in(state.live[{:query, ref}], wref)
  end

  defp query_frame(wref, %{kind: :browse} = q),
    do: ["browse", wref, q.ifindex, q.type, q.domain || ""]

  defp query_frame(wref, %{kind: :resolve} = q),
    do: ["resolve", wref, q.ifindex, q.name, q.type, q.domain]

  defp query_frame(wref, %{kind: :addrinfo} = q) do
    families =
      Enum.map_join([inet: "4", inet6: "6"], fn {f, c} -> if f in q.families, do: c, else: "" end)

    ["addrinfo", wref, q.ifindex, families, q.host]
  end

  defp drop_query(state, ref) do
    case Map.pop(state.queries, ref) do
      {nil, _} ->
        state

      {q, queries} ->
        Process.demonitor(q.monitor, [:flush])
        state = %{state | queries: queries}

        case Map.pop(state.live, {:query, ref}) do
          {nil, _} -> state
          {wref, live} -> forget(%{state | live: live}, wref)
        end
    end
  end

  # --- Owners ---

  defp watch(%{owner: owner} = entry, owner), do: entry

  defp watch(entry, owner) do
    if entry[:monitor], do: Process.demonitor(entry.monitor, [:flush])
    Map.merge(entry, %{owner: owner, monitor: Process.monitor(owner)})
  end

  defp notify(owner, tag, event), do: send(owner, {:bonjex, tag, event})
end
