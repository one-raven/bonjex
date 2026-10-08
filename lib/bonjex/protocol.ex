# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.Protocol do
  @moduledoc false
  # The framing spoken with `bonjex_port`; see the header of
  # `c_src/bonjex_port.c` for the full protocol. Fields are TAB-separated, and
  # `\`, TAB and LF inside a field are escaped as `\\`, `\t` and `\n`.

  alias Bonjex.{Error, TXT}

  @doc "Encodes one command frame."
  @spec encode([String.Chars.t()]) :: iolist()
  def encode(fields) do
    fields
    |> Enum.map(&escape(to_string(&1)))
    |> Enum.intersperse(?\t)
  end

  @doc "Decodes one reply frame. Unknown or malformed frames are `:unknown`."
  @spec decode(binary()) :: term()
  def decode(data) do
    data |> :binary.split("\t", [:global]) |> Enum.map(&unescape/1) |> parse()
  catch
    _, _ -> :unknown
  end

  defp parse(["up"]), do: :up
  defp parse(["fatal", code]), do: {:fatal, Error.reason(int(code))}
  defp parse(["ok", ref]), do: {:ok, ref}

  defp parse(["ok", ref, name, type, domain]),
    do: {:registered, ref, %{name: name, type: type, domain: domain}}

  defp parse(["err", ref, code]), do: {:error, ref, Error.reason(int(code))}

  defp parse(["browse", ref, op, ifindex, ifname, name, type, domain, more]) do
    {:event, ref,
     {op(op),
      %{
        name: name,
        type: type,
        domain: domain,
        ifindex: int(ifindex),
        interface: blank(ifname),
        more_coming: more == "1"
      }}}
  end

  defp parse(["resolved", ref, ifindex, ifname, host, port, txt_hex, more]) do
    {:event, ref,
     {:resolved,
      %{
        host: host,
        port: int(port),
        txt: txt_hex |> Base.decode16!(case: :mixed) |> TXT.decode(),
        ifindex: int(ifindex),
        interface: blank(ifname),
        more_coming: more == "1"
      }}}
  end

  defp parse(["addr", ref, op, ifindex, ifname, host, ip, ttl, more]) do
    {:ok, address} = ip |> String.to_charlist() |> :inet.parse_address()

    {:event, ref,
     {op(op),
      %{
        host: host,
        address: address,
        ttl: int(ttl),
        ifindex: int(ifindex),
        interface: blank(ifname),
        more_coming: more == "1"
      }}}
  end

  defp parse(_), do: :unknown

  defp op("add"), do: :add
  defp op("rmv"), do: :remove

  defp int(s), do: String.to_integer(s)

  defp blank(""), do: nil
  defp blank(s), do: s

  @doc false
  def escape(s) do
    if String.contains?(s, ["\\", "\t", "\n"]),
      do: for(<<c <- s>>, into: "", do: escape_char(c)),
      else: s
  end

  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(c), do: <<c>>

  @doc false
  def unescape(s) do
    if String.contains?(s, "\\"), do: unescape(s, <<>>), else: s
  end

  defp unescape(<<?\\, ?t, rest::binary>>, acc), do: unescape(rest, <<acc::binary, ?\t>>)
  defp unescape(<<?\\, ?n, rest::binary>>, acc), do: unescape(rest, <<acc::binary, ?\n>>)
  defp unescape(<<?\\, c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)
  defp unescape(<<>>, acc), do: acc
end
