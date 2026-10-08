# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

# Drives the real port program against the host's real DNS-SD responder. A
# fake would only assert our own assumptions back at us. On macOS this is the
# system mDNSResponder.
#
# Where libdns_sd was missing at build time there is no port program, and
# these tests do not exist rather than pass vacuously.
if File.exists?(Bonjex.Transport.Port.default_executable()) do
  defmodule Bonjex.LiveTest do
    use ExUnit.Case, async: false

    @moduletag :live
    @timeout 5_000

    setup do
      publisher = start_supervised!({Bonjex, name: :publisher}, id: :publisher)
      browser = start_supervised!({Bonjex, name: :browser}, id: :browser)
      assert eventually(fn -> Bonjex.connected?(publisher) and Bonjex.connected?(browser) end)
      %{pub: publisher, conn: browser}
    end

    defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

    test "a registration is browsed, resolved and its proxy addresses found", ctx do
      name = unique("bonjex test\tservice")
      host = "#{unique("bonjex-host")}.local."

      :ok =
        Bonjex.register(ctx.pub, :svc,
          name: name,
          type: "_bonjex._tcp",
          port: 4242,
          host: host,
          addresses: [{10, 99, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 0x99}],
          txt: %{"path" => "/x", "bin" => <<0, 255>>, "flag" => true}
        )

      assert_receive {:bonjex, {:service, :svc}, {:registered, %{name: ^name}}}, @timeout

      {:ok, browse} = Bonjex.browse(ctx.conn, "_bonjex._tcp")
      assert_receive {:bonjex, ^browse, :started}
      assert_receive {:bonjex, ^browse, {:add, %{name: ^name, domain: domain}}}, @timeout

      {:ok, resolve} = Bonjex.resolve(ctx.conn, name, "_bonjex._tcp", domain: domain)
      assert_receive {:bonjex, ^resolve, {:resolved, info}}, @timeout
      assert info.port == 4242
      assert String.downcase(info.host) == host
      assert info.txt == %{"path" => "/x", "bin" => <<0, 255>>, "flag" => true}

      {:ok, addrs} = Bonjex.get_addr_info(ctx.conn, info.host)
      found = collect_addresses(addrs, MapSet.new(), 2)
      assert MapSet.equal?(found, MapSet.new([{10, 99, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 0x99}]))
    end

    test "a subtype browse finds only that subtype", ctx do
      mine = unique("bonjex-sub")
      other = unique("bonjex-other")

      :ok =
        Bonjex.register(ctx.pub, :mine,
          name: mine,
          type: "_bonjex._tcp",
          subtypes: ["_s1"],
          port: 1
        )

      :ok = Bonjex.register(ctx.pub, :other, name: other, type: "_bonjex._tcp", port: 2)
      assert_receive {:bonjex, {:service, :mine}, {:registered, _}}, @timeout
      assert_receive {:bonjex, {:service, :other}, {:registered, _}}, @timeout

      {:ok, ref} = Bonjex.browse(ctx.conn, "_bonjex._tcp", subtype: "_s1")
      assert_receive {:bonjex, ^ref, {:add, %{name: ^mine}}}, @timeout
      refute_receive {:bonjex, ^ref, {:add, %{name: ^other}}}, 1_000
    end

    test "a TXT change reaches a standing resolve without the service going away", ctx do
      name = unique("bonjex-txt")
      opts = [name: name, type: "_bonjex._tcp", port: 3, txt: %{"v" => "1"}]

      :ok = Bonjex.register(ctx.pub, :svc, opts)
      assert_receive {:bonjex, {:service, :svc}, {:registered, _}}, @timeout

      {:ok, browse} = Bonjex.browse(ctx.conn, "_bonjex._tcp")
      assert_receive {:bonjex, ^browse, {:add, %{name: ^name}}}, @timeout

      {:ok, resolve} = Bonjex.resolve(ctx.conn, name, "_bonjex._tcp")
      assert_receive {:bonjex, ^resolve, {:resolved, %{txt: %{"v" => "1"}}}}, @timeout

      :ok = Bonjex.register(ctx.pub, :svc, Keyword.put(opts, :txt, %{"v" => "2"}))
      assert_receive {:bonjex, ^resolve, {:resolved, %{txt: %{"v" => "2"}}}}, @timeout
      refute_received {:bonjex, ^browse, {:remove, %{name: ^name}}}
    end

    test "unregistering is seen as a browse remove", ctx do
      name = unique("bonjex-gone")
      :ok = Bonjex.register(ctx.pub, :svc, name: name, type: "_bonjex._tcp", port: 4)

      {:ok, ref} = Bonjex.browse(ctx.conn, "_bonjex._tcp")
      assert_receive {:bonjex, ^ref, {:add, %{name: ^name}}}, @timeout

      :ok = Bonjex.unregister(ctx.pub, :svc)
      assert_receive {:bonjex, ^ref, {:remove, %{name: ^name}}}, @timeout
    end

    defp collect_addresses(_ref, found, 0), do: found

    defp collect_addresses(ref, found, left) do
      receive do
        {:bonjex, ^ref, {:add, %{address: ip}}} ->
          if MapSet.member?(found, ip),
            do: collect_addresses(ref, found, left),
            else: collect_addresses(ref, MapSet.put(found, ip), left - 1)

        {:bonjex, ^ref, _} ->
          collect_addresses(ref, found, left)
      after
        @timeout -> found
      end
    end

    defp eventually(fun, timeout \\ 3_000) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_eventually(fun, deadline)
    end

    defp do_eventually(fun, deadline) do
      cond do
        fun.() -> true
        System.monotonic_time(:millisecond) >= deadline -> false
        true -> Process.sleep(50) && do_eventually(fun, deadline)
      end
    end
  end
end
