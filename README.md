<!--
SPDX-FileCopyrightText: 2026 One Raven, Inc.
SPDX-FileContributor: Ben Youngblood

SPDX-License-Identifier: Apache-2.0
-->

# Bonjex

[![Hex version](https://img.shields.io/hexpm/v/bonjex.svg "Hex version")](https://hex.pm/packages/bonjex)
[![API docs](https://img.shields.io/hexpm/v/bonjex.svg?label=docs "API docs")](https://hexdocs.pm/bonjex)

DNS-SD (Bonjour, Zeroconf) for Elixir through the system mDNS responder.

Bonjex registers, browses, resolves and looks up addresses through
`libdns_sd`, the client library of Apple's mDNSResponder. It is not an mDNS
implementation and opens no sockets of its own. The daemon owns UDP 5353:
it probes for name conflicts, suppresses known answers and duplicate
questions, backs off between repeats, and keeps one cache for every client on
the host. That makes Bonjex a good neighbour on a busy network and keeps it
out of the way of anything else on the host that does mDNS.

It runs the client library in a small port program, not a NIF, so a slow or
wedged daemon cannot block a BEAM scheduler.

## Features

- Register services, with subtypes, TXT records, and proxy hosts with their
  own A/AAAA records (for advertising on behalf of another device)
- Update a TXT record in place, without the service leaving the network
- Long-lived browse, resolve and address queries that report every change
- Starts before the daemon does, and reconnects forever: registrations and
  queries are replayed whenever the connection comes back
- Registrations and queries are tied to the process that made them

## Requirements

- **macOS**: nothing extra. The SDK has `dns_sd.h` and libSystem has the
  library.
- **Linux and Nerves**: Apple's
  [mDNSResponder](https://github.com/apple-oss-distributions/mDNSResponder),
  built from its `mDNSPosix` directory, which provides the `mdnsd` daemon,
  `dns_sd.h` and `libdns_sd`.

> #### mDNSResponder on Linux and Nerves {: .warning}
>
> - Use `mDNSResponder-2881.40.18` or later. Older tags' `libdns_sd` calls
>   the BSD-only `issetugid()`, so nothing linked against it builds with glibc
>   or musl.
> - Start `mdnsd` before or alongside your application.
> - Avahi's compatibility library is not supported: it lacks the shared
>   connections and record registration Bonjex uses.
>
> On Nerves, add mDNSResponder to your system so that `dns_sd.h` and
> `libdns_sd` land in its sysroot. A cross build fails if the header is
> missing, rather than shipping firmware with no DNS-SD.

On a host build with no `libdns_sd`, the port program is skipped with a
warning, so the library still compiles and its unit tests run. Set
`BONJEX_REQUIRE_PORT=1` to make that an error.

## Installation

```elixir
def deps do
  [{:bonjex, "~> 0.1"}]
end
```

## Usage

Start a connection, usually in your supervision tree:

```elixir
children = [{Bonjex, name: MyApp.Bonjex}]
```

Register a service:

```elixir
:ok =
  Bonjex.register(MyApp.Bonjex, :web,
    name: "My Server",
    type: "_http._tcp",
    port: 8080,
    txt: %{path: "/"}
  )

# Later, with only the TXT changed, this updates the record in place:
:ok = Bonjex.register(MyApp.Bonjex, :web, name: "My Server", type: "_http._tcp", port: 8080, txt: %{path: "/v2"})
```

Find services. Results arrive as messages to the process that asked:

```elixir
{:ok, browse} = Bonjex.browse(MyApp.Bonjex, "_http._tcp")

receive do
  {:bonjex, ^browse, {:add, %{name: name, type: type, domain: domain, ifindex: ifindex}}} ->
    {:ok, resolve} = Bonjex.resolve(MyApp.Bonjex, name, type, domain: domain, ifindex: ifindex)

    receive do
      {:bonjex, ^resolve, {:resolved, %{host: host, port: port, txt: txt}}} ->
        {:ok, addrs} = Bonjex.get_addr_info(MyApp.Bonjex, host)
        # {:bonjex, ^addrs, {:add, %{address: {192, 168, 1, 20}}}}
    end
end
```

Queries run until `Bonjex.cancel/2`, or until the process that made them
exits. Each one also receives `:started` whenever it is sent to the daemon,
and `:interrupted` when the connection is lost. See the `Bonjex` module docs
for every message.

## Testing

```sh
mix test                 # unit tests, against a fake port
mix test --include live  # also against this host's real responder
```

## AI Usage Disclosure

The initial implementation of this library was authored largely by Claude Opus 5.5.
