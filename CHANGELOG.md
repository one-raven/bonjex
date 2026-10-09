<!--
SPDX-FileCopyrightText: 2026 One Raven, Inc.
SPDX-FileContributor: Ben Youngblood

SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [v0.1.1]

- Fix cross builds on macOS: link `-ldns_sd` whenever `CROSSCOMPILE` is set,
  instead of skipping it because the build host is Darwin.

## [v0.1.0]

Initial release.

- `Bonjex` connections to the system DNS-SD responder through `libdns_sd`,
  run in a port program so a wedged daemon cannot block a scheduler.
- Service registration with subtypes, TXT records, domains, interface
  scoping and optional automatic renaming.
- Proxy hosts with their own A/AAAA records, shared between the services
  that name them.
- In-place TXT updates when only the TXT record changes.
- Long-lived browse, resolve and address queries reporting every change.
- Reconnection with capped exponential backoff, replaying every registration
  and query.
- Registrations and queries tied to the lifetime of the process that made
  them.
- `Bonjex.TXT` for encoding and decoding TXT records.
