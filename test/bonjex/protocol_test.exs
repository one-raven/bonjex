# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.ProtocolTest do
  use ExUnit.Case, async: true

  alias Bonjex.Protocol

  test "fields are escaped so names may hold TAB, LF and backslash" do
    for s <- ["plain", "a\tb", "a\nb", "a\\b", "\\t", "x\\\\\t"] do
      assert s |> Protocol.escape() |> Protocol.unescape() == s
      refute Protocol.escape(s) =~ "\t"
    end
  end

  test "decodes a browse result" do
    assert Protocol.decode("browse\t3\tadd\t4\ten0\tMy\\tPrinter\t_ipp._tcp.\tlocal.\t1") ==
             {:event, "3",
              {:add,
               %{
                 name: "My\tPrinter",
                 type: "_ipp._tcp.",
                 domain: "local.",
                 ifindex: 4,
                 interface: "en0",
                 more_coming: true
               }}}
  end

  test "decodes a resolve result with its TXT" do
    assert {:event, "1", {:resolved, %{host: "h.local.", port: 80, txt: %{"a" => "1"}}}} =
             Protocol.decode("resolved\t1\t0\t\th.local.\t80\t03613d31\t0")
  end

  test "decodes an address, with no interface name" do
    assert {:event, "2", {:remove, %{address: {0xFD00, 0, 0, 0, 0, 0, 0, 1}, interface: nil}}} =
             Protocol.decode("addr\t2\trmv\t0\t\th.local.\tfd00::1\t120\t0")
  end

  test "decodes errors by name" do
    assert Protocol.decode("err\t7\t-65548") == {:error, "7", :name_conflict}
    assert Protocol.decode("err\t7\t-1") == {:error, "7", {:dns_service_error, -1}}
  end

  test "malformed frames are unknown" do
    assert Protocol.decode("browse\t1") == :unknown
    assert Protocol.decode("resolved\t1\t0\t\th\tnotaport\t\t0") == :unknown
  end
end
