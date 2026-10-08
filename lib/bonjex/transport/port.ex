# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.Transport.Port do
  @moduledoc """
  The default transport: one `bonjex_port` OS process per connection.

  Takes the `:executable` option, defaulting to `priv/bonjex_port` in the
  `:bonjex` application.
  """

  @behaviour Bonjex.Transport

  @impl true
  def open(opts) do
    path = Keyword.get_lazy(opts, :executable, &default_executable/0)

    if File.exists?(path) do
      {:ok, Port.open({:spawn_executable, path}, [{:packet, 4}, :binary, :exit_status, :hide])}
    else
      {:error, {:not_found, path}}
    end
  end

  @impl true
  def command(port, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Where the port program is installed."
  @spec default_executable() :: Path.t()
  def default_executable, do: Application.app_dir(:bonjex, ["priv", "bonjex_port"])
end
