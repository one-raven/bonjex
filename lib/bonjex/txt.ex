# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.TXT do
  @moduledoc """
  DNS-SD TXT records (RFC 6763 §6).

  A TXT record is a map of keys to values. A value is a binary (which may be
  empty, or not valid UTF-8), or `true` for a boolean attribute: a key that
  is present with no `=`.
  """

  @type value :: binary() | true
  @type t :: %{optional(String.t()) => value()}

  @doc """
  Decodes raw TXT rdata, a run of length-prefixed strings.

  Empty strings are skipped (an empty TXT record is a single one). A truncated
  trailing string is dropped rather than failing the record. When a key
  appears more than once, the first wins (RFC 6763 §6.4). Keys keep the case
  they were sent in, though DNS-SD compares them case-insensitively.

      iex> Bonjex.TXT.decode(<<6, "path=/", 3, "tls">>)
      %{"path" => "/", "tls" => true}
  """
  @spec decode(binary()) :: t()
  def decode(rdata) when is_binary(rdata), do: decode(rdata, %{})

  defp decode(<<>>, acc), do: acc
  defp decode(<<0, rest::binary>>, acc), do: decode(rest, acc)

  defp decode(<<len, str::binary-size(len), rest::binary>>, acc) do
    {key, value} =
      case :binary.split(str, "=") do
        [key, value] -> {key, value}
        [key] -> {key, true}
      end

    acc = if key == "", do: acc, else: Map.put_new(acc, key, value)
    decode(rest, acc)
  end

  defp decode(_truncated, acc), do: acc

  @doc """
  Validates and normalizes a TXT map or keyword list given by a caller.

  Keys may be strings or atoms; values may be binaries, `true`, or anything
  with a `String.Chars` implementation. `false` and `nil` values are left
  out. Raises `ArgumentError` for a key that is empty or contains `=`, or for
  an entry longer than 255 bytes.
  """
  @spec normalize(Enumerable.t()) :: [{String.t(), value()}]
  def normalize(txt) do
    txt
    |> Enum.reject(fn {_k, v} -> v in [nil, false] end)
    |> Enum.map(fn {k, v} ->
      check({to_string(k), if(v == true, do: true, else: to_string(v))})
    end)
    |> Enum.sort()
  end

  defp check({key, value} = entry) do
    if key == "" or String.contains?(key, "=") do
      raise ArgumentError, "invalid TXT key #{inspect(key)}"
    end

    size = byte_size(key) + if(value == true, do: 0, else: 1 + byte_size(value))

    if size > 255 do
      raise ArgumentError, "TXT entry #{inspect(key)} is #{size} bytes; the limit is 255"
    end

    entry
  end
end
