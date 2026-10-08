# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.ConnectionTest do
  use ExUnit.Case, async: true

  alias Bonjex.FakeTransport, as: Fake

  setup do
    conn = start_supervised!({Bonjex, transport: Fake, test: self(), backoff_min: 10})
    assert_receive {:fake_port, port, ^conn}
    %{conn: conn, port: port}
  end

  defp up(%{conn: conn, port: port}) do
    Fake.reply(conn, port, ["up"])
    wait(conn)
  end

  # A call returns only after every message sent before it was handled.
  defp wait(conn), do: Bonjex.connected?(conn)

  defp reconnect(%{conn: conn, port: port}) do
    Fake.exit(conn, port)
    assert_receive {:fake_port, port, ^conn}
    Fake.reply(conn, port, ["up"])
    wait(conn)
    port
  end

  describe "registering" do
    test "waits for the responder, then sends the registration", ctx do
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80, txt: %{path: "/"})
      refute_received {:frame, _}

      up(ctx)

      assert_receive {:frame,
                      ["register", ref, "0", "", "", "_http._tcp", "", "", "80", "path=2f"]}

      Fake.reply(ctx.conn, ctx.port, ["ok", ref, "Host", "_http._tcp.", "local."])

      assert_receive {:bonjex, {:service, :web},
                      {:registered, %{name: "Host", type: "_http._tcp.", domain: "local."}}}
    end

    test "carries name, subtypes, domain and flags", ctx do
      up(ctx)

      :ok =
        Bonjex.register(ctx.conn, :p,
          name: "Office\tPrinter",
          type: "_ipp._tcp",
          subtypes: ["_universal", "_print"],
          domain: "example.com.",
          port: 631,
          rename: false,
          txt: [flag: true]
        )

      assert_receive {:frame,
                      [
                        "register",
                        _,
                        "0",
                        "n",
                        "Office\tPrinter",
                        "_ipp._tcp,_print,_universal",
                        "example.com.",
                        "",
                        "631",
                        "flag"
                      ]}
    end

    test "the same options again do nothing", ctx do
      up(ctx)
      opts = [type: "_http._tcp", port: 80, txt: %{a: "1"}]
      :ok = Bonjex.register(ctx.conn, :web, opts)
      assert_receive {:frame, ["register" | _]}

      :ok = Bonjex.register(ctx.conn, :web, Keyword.put(opts, :txt, [{"a", "1"}]))
      wait(ctx.conn)
      refute_received {:frame, _}
    end

    test "a TXT-only change updates in place", ctx do
      up(ctx)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80, txt: %{a: "1"})
      assert_receive {:frame, ["register", ref | _]}

      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80, txt: %{a: "2"})
      assert_receive {:frame, ["update", ^ref, "a=32"]}
    end

    test "any other change replaces the registration", ctx do
      up(ctx)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80)
      assert_receive {:frame, ["register", old | _]}

      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 81)
      assert_receive {:frame, ["remove", ^old]}
      assert_receive {:frame, ["register", new, _, _, _, _, _, _, "81"]}
      assert new != old
    end

    test "unregister withdraws it", ctx do
      up(ctx)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80)
      assert_receive {:frame, ["register", ref | _]}

      :ok = Bonjex.unregister(ctx.conn, :web)
      assert_receive {:frame, ["remove", ^ref]}
      assert Bonjex.registered(ctx.conn) == []
    end

    test "errors reach the owner", ctx do
      up(ctx)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80, rename: false)
      assert_receive {:frame, ["register", ref | _]}

      Fake.reply(ctx.conn, ctx.port, ["err", ref, "-65548"])
      assert_receive {:bonjex, {:service, :web}, {:error, :name_conflict}}
    end

    test "bad options raise in the caller", ctx do
      assert_raise ArgumentError, fn -> Bonjex.register(ctx.conn, :x, port: 80) end
      assert_raise ArgumentError, fn -> Bonjex.register(ctx.conn, :x, type: "_a._tcp") end

      assert_raise ArgumentError, fn ->
        Bonjex.register(ctx.conn, :x, type: "_a._tcp", port: 70_000)
      end

      assert_raise ArgumentError, fn ->
        Bonjex.register(ctx.conn, :x, type: "_a._tcp", port: 1, host: "h", addresses: ["nope"])
      end

      assert_raise ArgumentError, fn ->
        Bonjex.register(ctx.conn, :x, type: "_a._tcp", port: 1, colour: :blue)
      end

      assert Process.alive?(ctx.conn)
    end

    test "is withdrawn when its owner exits", ctx do
      up(ctx)
      test = self()

      owner =
        spawn(fn ->
          :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80)
          send(test, :registered)
          receive do: (:stop -> :ok)
        end)

      assert_receive :registered
      assert_receive {:frame, ["register", ref | _]}

      send(owner, :stop)
      assert_receive {:frame, ["remove", ^ref]}
      assert Bonjex.registered(ctx.conn) == []
    end
  end

  describe "proxy hosts" do
    test "publish their addresses, and services sharing a host share them", ctx do
      up(ctx)
      opts = [type: "_http._tcp", port: 80, host: "dev-1", addresses: [{10, 0, 0, 5}, "fd00::5"]]

      :ok = Bonjex.register(ctx.conn, :a, opts)
      assert_receive {:frame, ["register", _, _, _, _, _, _, "dev-1.local.", "80"]}
      assert_receive {:frame, ["record", r4, "0", "dev-1.local.", "10.0.0.5", "120"]}
      assert_receive {:frame, ["record", r6, "0", "dev-1.local.", "fd00::5", "120"]}

      :ok = Bonjex.register(ctx.conn, :b, Keyword.put(opts, :type, "_ssh._tcp"))
      assert_receive {:frame, ["register", b | _]}
      wait(ctx.conn)
      refute_received {:frame, ["record" | _]}

      :ok = Bonjex.unregister(ctx.conn, :a)
      wait(ctx.conn)
      refute_received {:frame, ["remove", ^r4]}

      :ok = Bonjex.unregister(ctx.conn, :b)
      assert_receive {:frame, ["remove", ^b]}
      assert_receive {:frame, ["remove", ^r4]}
      assert_receive {:frame, ["remove", ^r6]}
    end

    test "a refused address reaches every service using it", ctx do
      up(ctx)
      opts = [type: "_http._tcp", port: 80, host: "dev-1.local.", addresses: [{10, 0, 0, 5}]]
      :ok = Bonjex.register(ctx.conn, :a, opts)
      :ok = Bonjex.register(ctx.conn, :b, Keyword.put(opts, :port, 81))
      assert_receive {:frame, ["record", ref | _]}

      Fake.reply(ctx.conn, ctx.port, ["err", ref, "-65548"])

      assert_receive {:bonjex, {:service, :a},
                      {:error, {:address, {10, 0, 0, 5}, :name_conflict}}}

      assert_receive {:bonjex, {:service, :b},
                      {:error, {:address, {10, 0, 0, 5}, :name_conflict}}}
    end
  end

  describe "queries" do
    test "browse reports :started, then what the daemon finds", ctx do
      {:ok, ref} = Bonjex.browse(ctx.conn, "_http._tcp", subtype: "_printer")
      refute_received {:bonjex, ^ref, _}

      up(ctx)
      assert_receive {:bonjex, ^ref, :started}
      assert_receive {:frame, ["browse", wref, "0", "_http._tcp,_printer", ""]}

      Fake.reply(ctx.conn, ctx.port, [
        "browse",
        wref,
        "add",
        "4",
        "en0",
        "Web",
        "_http._tcp.",
        "local.",
        "0"
      ])

      assert_receive {:bonjex, ^ref,
                      {:add,
                       %{
                         name: "Web",
                         type: "_http._tcp.",
                         domain: "local.",
                         ifindex: 4,
                         interface: "en0",
                         more_coming: false
                       }}}
    end

    test "resolve and get_addr_info send their arguments", ctx do
      up(ctx)
      {:ok, _} = Bonjex.resolve(ctx.conn, "Web", "_http._tcp", ifindex: 4)
      assert_receive {:frame, ["resolve", _, "4", "Web", "_http._tcp", "local."]}

      {:ok, _} = Bonjex.get_addr_info(ctx.conn, "h.local.")
      assert_receive {:frame, ["addrinfo", _, "0", "46", "h.local."]}

      {:ok, _} = Bonjex.get_addr_info(ctx.conn, "h.local.", families: [:inet6])
      assert_receive {:frame, ["addrinfo", _, "0", "6", "h.local."]}

      assert_raise ArgumentError, fn -> Bonjex.get_addr_info(ctx.conn, "h", families: []) end
      assert_raise ArgumentError, fn -> Bonjex.browse(ctx.conn, "_a._tcp", ifindex: -1) end
    end

    test "cancel stops the query and drops what is queued for it", ctx do
      up(ctx)
      {:ok, ref} = Bonjex.browse(ctx.conn, "_http._tcp")
      assert_receive {:frame, ["browse", wref | _]}

      :ok = Bonjex.cancel(ctx.conn, ref)
      assert_receive {:frame, ["remove", ^wref]}
      refute_received {:bonjex, ^ref, _}

      # A result already in flight for it goes nowhere.
      Fake.reply(ctx.conn, ctx.port, ["browse", wref, "add", "0", "", "W", "_h._tcp.", "l.", "0"])
      wait(ctx.conn)
      refute_received {:bonjex, ^ref, _}
    end

    test "errors are reported and the query is kept", ctx do
      up(ctx)
      {:ok, ref} = Bonjex.browse(ctx.conn, "_http._tcp")
      assert_receive {:frame, ["browse", wref | _]}

      Fake.reply(ctx.conn, ctx.port, ["err", wref, "-65540"])
      assert_receive {:bonjex, ^ref, {:error, :bad_param}}

      reconnect(ctx)
      assert_receive {:frame, ["browse" | _]}
    end

    test "are cancelled when their owner exits", ctx do
      up(ctx)
      test = self()

      owner =
        spawn(fn ->
          {:ok, _} = Bonjex.browse(ctx.conn, "_http._tcp")
          send(test, :browsing)
          receive do: (:stop -> :ok)
        end)

      assert_receive :browsing
      assert_receive {:frame, ["browse", wref | _]}

      send(owner, :stop)
      assert_receive {:frame, ["remove", ^wref]}
    end
  end

  describe "reconnecting" do
    test "interrupts, then replays everything on fresh refs", ctx do
      up(ctx)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80)
      {:ok, ref} = Bonjex.browse(ctx.conn, "_http._tcp")
      assert_receive {:frame, ["register", old_svc | _]}
      assert_receive {:frame, ["browse", old_q | _]}
      assert_receive {:bonjex, ^ref, :started}

      Fake.exit(ctx.conn, ctx.port)
      assert_receive {:bonjex, {:service, :web}, :interrupted}
      assert_receive {:bonjex, ^ref, :interrupted}
      refute Bonjex.connected?(ctx.conn)

      assert_receive {:fake_port, port, _}
      Fake.reply(ctx.conn, port, ["up"])

      assert_receive {:frame, ["register", new_svc | _]}
      assert_receive {:bonjex, ^ref, :started}
      assert_receive {:frame, ["browse", new_q | _]}
      assert new_svc not in [old_svc, old_q]
      assert new_q not in [old_svc, old_q]

      # A reply for the old port's ref matches nothing.
      Fake.reply(ctx.conn, port, ["err", old_svc, "-65548"])
      wait(ctx.conn)
      refute_received {:bonjex, _, {:error, _}}
    end

    test "changes made while down are sent once connected", ctx do
      up(ctx)
      Fake.exit(ctx.conn, ctx.port)
      assert_receive {:fake_port, port, _}

      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 80)
      :ok = Bonjex.register(ctx.conn, :web, type: "_http._tcp", port: 81)
      wait(ctx.conn)
      refute_received {:frame, _}

      Fake.reply(ctx.conn, port, ["up"])
      assert_receive {:frame, ["register", _, _, _, _, _, _, _, "81"]}
      wait(ctx.conn)
      refute_received {:frame, _}
    end

    test "a port that never comes up interrupts nothing", ctx do
      {:ok, ref} = Bonjex.browse(ctx.conn, "_http._tcp")
      Fake.reply(ctx.conn, ctx.port, ["fatal", "-65563"])
      Fake.exit(ctx.conn, ctx.port)
      assert_receive {:fake_port, _, _}
      refute_received {:bonjex, ^ref, _}
    end
  end
end
