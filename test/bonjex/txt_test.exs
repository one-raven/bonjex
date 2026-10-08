# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.TXTTest do
  use ExUnit.Case, async: true

  alias Bonjex.TXT

  doctest Bonjex.TXT

  describe "decode/1" do
    test "key=value pairs" do
      assert TXT.decode(<<6, "D=1880", 4, "CM=2">>) == %{"D" => "1880", "CM" => "2"}
    end

    test "a bare key is a boolean attribute" do
      assert TXT.decode(<<2, "PI">>) == %{"PI" => true}
    end

    test "an empty value is kept" do
      assert TXT.decode(<<2, "K=">>) == %{"K" => ""}
    end

    test "empty strings are skipped" do
      assert TXT.decode(<<0, 6, "D=1880">>) == %{"D" => "1880"}
      assert TXT.decode(<<0>>) == %{}
      assert TXT.decode(<<>>) == %{}
    end

    test "a truncated trailing string is dropped" do
      assert TXT.decode(<<4, "CM=2", 20, "abc">>) == %{"CM" => "2"}
    end

    test "the first of a repeated key wins" do
      assert TXT.decode(<<3, "a=1", 3, "a=2">>) == %{"a" => "1"}
    end

    test "an entry with no key is ignored" do
      assert TXT.decode(<<2, "=x", 3, "a=1">>) == %{"a" => "1"}
    end

    test "binary values pass through" do
      assert TXT.decode(<<6, "RI=", 0xFF, 0xFE, 0xFD>>) == %{"RI" => <<0xFF, 0xFE, 0xFD>>}
    end
  end

  describe "normalize/1" do
    test "takes maps and keyword lists, and drops nil and false" do
      assert TXT.normalize(%{"b" => 2, a: "x", c: true, d: nil, e: false}) ==
               [{"a", "x"}, {"b", "2"}, {"c", true}]
    end

    test "rejects keys with = or no keys at all" do
      assert_raise ArgumentError, fn -> TXT.normalize(%{"a=b" => "1"}) end
      assert_raise ArgumentError, fn -> TXT.normalize(%{"" => "1"}) end
    end

    test "rejects entries over 255 bytes" do
      assert TXT.normalize(%{"k" => String.duplicate("x", 253)}) |> length() == 1
      assert_raise ArgumentError, fn -> TXT.normalize(%{"k" => String.duplicate("x", 254)}) end
    end
  end
end
