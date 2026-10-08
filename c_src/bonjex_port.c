// SPDX-FileCopyrightText: 2026 One Raven, Inc.
// SPDX-FileContributor: Ben Youngblood
//
// SPDX-License-Identifier: Apache-2.0

/*
 * bonjex_port.c — an Erlang port program that speaks to the system DNS-SD
 * responder (Apple's mDNSResponder, or `mdnsd` on Linux) through `libdns_sd`.
 *
 * ## Why a port program and not a NIF
 *
 * `DNSServiceRegister` and friends talk to the daemon over an AF_UNIX socket
 * and can block; a wedged daemon can stall a caller for the client library's
 * full timeout. In a NIF that stalls a BEAM scheduler. In a separate OS
 * process it stalls nothing, and the BEAM side simply sees the port go quiet.
 *
 * ## Ownership model
 *
 * This program holds no desired state. Elixir owns the full set of
 * registrations and queries; this program executes them, keyed by an opaque
 * integer `ref` that Elixir assigns. When the port dies (daemon absent,
 * daemon restarted, connection dropped) Elixir starts a new one and replays
 * everything. That is what lets a caller register before the daemon exists.
 *
 * Every operation shares one daemon connection
 * (`kDNSServiceFlagsShareConnection`), so one select() loop serves them all.
 *
 * ## Wire protocol
 *
 * stdin/stdout, 4-byte big-endian length framing (Erlang `{:packet, 4}`).
 * One message per frame, fields separated by TAB. Within a field, `\`, TAB
 * and LF are escaped as `\\`, `\t` and `\n`, so DNS names may contain any
 * byte. An empty field means "none" wherever a name is optional.
 *
 * Commands in:
 *   register REF IFINDEX FLAGS INSTANCE REGTYPE DOMAIN HOST PORT [TXT...]
 *       REGTYPE may carry subtypes comma-separated ("_http._tcp,_printer"),
 *       libdns_sd's native subtype syntax. Empty INSTANCE takes the host's
 *       name; empty DOMAIN the default domain; empty HOST the daemon's own
 *       hostname. FLAGS is a set of letters: `n` = no automatic rename.
 *   record REF IFINDEX HOSTNAME IP TTL
 *       A or AAAA (by whether IP contains ':') for a proxy host. Registered
 *       Unique, so the daemon probes for conflicts and sets cache-flush.
 *   update REF [TXT...]
 *       Replaces a live registration's TXT in place (DNSServiceUpdateRecord),
 *       so the service never leaves the network while its TXT changes.
 *   browse REF IFINDEX REGTYPE DOMAIN
 *   resolve REF IFINDEX INSTANCE REGTYPE DOMAIN
 *   addrinfo REF IFINDEX PROTOCOLS HOSTNAME
 *       PROTOCOLS: "4", "6" or "46".
 *   remove REF
 *
 *   TXT fields are KEY=HEXVALUE, or a bare KEY for a boolean attribute.
 *   Values are hex so binary values survive the text framing.
 *
 *   browse, resolve and addrinfo are long-lived: they report every change
 *   until `remove`. The daemon runs the RFC 6762 querier behind them
 *   (known-answer suppression, duplicate question suppression, backoff,
 *   refresh near TTL expiry) and shares one cache across every client.
 *
 * Replies out:
 *   up                                  connected to the daemon
 *   fatal CODE                          followed by exit(1)
 *   ok REF NAME REGTYPE DOMAIN          a registration is live (again, after
 *                                       an automatic rename)
 *   ok REF                              a record or TXT update was accepted
 *   err REF CODE                        a DNSServiceErrorType
 *   browse REF add|rmv IFINDEX IFNAME NAME REGTYPE DOMAIN MORE
 *   resolved REF IFINDEX IFNAME HOSTTARGET PORT TXTHEX MORE
 *   addr REF add|rmv IFINDEX IFNAME HOSTNAME IP TTL MORE
 *
 *   IFNAME is empty when the index names no interface. MORE is 1 while the
 *   daemon has more answers queued (kDNSServiceFlagsMoreComing). The flag
 *   covers the whole shared connection, not just this query.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

#include <dns_sd.h>

#define MAX_FRAME (128 * 1024)
#define MAX_FIELDS 512
/* One slot per live registration, record or query. A full table answers
 * NoMemory and the operation never runs. */
#define MAX_ENTRIES 4096
#define MAX_TXT 8192

typedef struct {
    int64_t ref;
    int in_use;
    int is_record;           /* 1 = proxy address, 0 = anything with an sd_ref */
    DNSServiceRef sd_ref;    /* subordinate ref, shares the main connection */
    DNSRecordRef record_ref; /* only when is_record */
} entry_t;

static DNSServiceRef g_conn = NULL;
static entry_t g_entries[MAX_ENTRIES];

/* ---------- framed IO ---------- */

static int read_exact(unsigned char *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(STDIN_FILENO, buf + got, len - got);
        if (n == 0) return 0; /* Elixir closed the port */
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)n;
    }
    return 1;
}

static void write_all(const void *p, size_t len)
{
    const unsigned char *b = p;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(STDOUT_FILENO, b + off, len - off);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            exit(2);
        }
        off += (size_t)n;
    }
}

static void write_frame(const char *s, size_t len)
{
    unsigned char hdr[4] = {(unsigned char)(len >> 24), (unsigned char)(len >> 16),
                            (unsigned char)(len >> 8), (unsigned char)len};
    write_all(hdr, 4);
    write_all(s, len);
}

/* An outgoing frame under construction. Callbacks never nest, so one will do. */
typedef struct {
    char buf[MAX_FRAME];
    size_t len;
    int overflow;
} out_t;

static out_t g_out;

static void out_start(const char *tag)
{
    g_out.len = 0;
    g_out.overflow = 0;
    size_t n = strlen(tag);
    memcpy(g_out.buf, tag, n);
    g_out.len = n;
}

static void out_byte(char c)
{
    if (g_out.len >= sizeof(g_out.buf)) {
        g_out.overflow = 1;
        return;
    }
    g_out.buf[g_out.len++] = c;
}

/* Appends TAB and then `s`, escaped. NULL is written as an empty field. */
static void out_str(const char *s)
{
    out_byte('\t');
    for (; s && *s; s++) {
        switch (*s) {
        case '\\': out_byte('\\'); out_byte('\\'); break;
        case '\t': out_byte('\\'); out_byte('t'); break;
        case '\n': out_byte('\\'); out_byte('n'); break;
        default: out_byte(*s);
        }
    }
}

static void out_fmt(const char *fmt, ...)
{
    char tmp[64];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    out_str(tmp);
}

static void out_hex(const unsigned char *p, size_t len)
{
    static const char hex[] = "0123456789abcdef";
    out_byte('\t');
    for (size_t i = 0; i < len; i++) {
        out_byte(hex[p[i] >> 4]);
        out_byte(hex[p[i] & 0x0f]);
    }
}

static void reply_err(int64_t ref, int code)
{
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "err\t%lld\t%d", (long long)ref, code);
    write_frame(buf, (size_t)n);
}

/* Sends the frame, or an error for `ref` if it did not fit. */
static void out_send(int64_t ref)
{
    if (g_out.overflow) {
        reply_err(ref, kDNSServiceErr_NoMemory);
        return;
    }
    write_frame(g_out.buf, g_out.len);
}

static void reply_ok(int64_t ref)
{
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "ok\t%lld", (long long)ref);
    write_frame(buf, (size_t)n);
}

static void fatal(int code)
{
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "fatal\t%d", code);
    write_frame(buf, (size_t)n);
    exit(1);
}

/* ---------- entry table ---------- */

static entry_t *entry_find(int64_t ref)
{
    for (int i = 0; i < MAX_ENTRIES; i++)
        if (g_entries[i].in_use && g_entries[i].ref == ref) return &g_entries[i];
    return NULL;
}

static void entry_free(entry_t *e)
{
    if (!e || !e->in_use) return;
    if (e->is_record) {
        /* Removing the record is enough; the shared connection stays. */
        if (e->record_ref && g_conn) DNSServiceRemoveRecord(g_conn, e->record_ref, 0);
    } else if (e->sd_ref) {
        /* Deallocating a subordinate ref does not tear down the parent. */
        DNSServiceRefDeallocate(e->sd_ref);
    }
    memset(e, 0, sizeof(entry_t));
}

/* Claims a slot for `ref`, replacing whatever held it. Replies NoMemory and
 * returns NULL when the table is full. */
static entry_t *entry_claim(int64_t ref)
{
    entry_t *e = entry_find(ref);
    if (e) entry_free(e);

    for (int i = 0; i < MAX_ENTRIES; i++)
        if (!g_entries[i].in_use) {
            g_entries[i].in_use = 1;
            g_entries[i].ref = ref;
            return &g_entries[i];
        }

    reply_err(ref, kDNSServiceErr_NoMemory);
    return NULL;
}

static void entry_started(entry_t *e, int64_t ref, DNSServiceErrorType err, DNSServiceRef sd)
{
    if (err != kDNSServiceErr_NoError) {
        entry_free(e);
        reply_err(ref, (int)err);
        return;
    }
    e->is_record = 0;
    e->sd_ref = sd;
}

/* ---------- parsing helpers ---------- */

/* Splits `line` in place on TAB and unescapes each field. */
static int split_fields(char *line, char **out, int max)
{
    int n = 0;
    char *p = line;
    out[n++] = p;
    for (; *p && n < max; p++)
        if (*p == '\t') {
            *p = '\0';
            out[n++] = p + 1;
        }

    for (int i = 0; i < n; i++) {
        char *r = out[i], *w = out[i];
        while (*r) {
            if (*r == '\\' && r[1]) {
                r++;
                *w++ = *r == 't' ? '\t' : *r == 'n' ? '\n' : *r;
                r++;
            } else {
                *w++ = *r++;
            }
        }
        *w = '\0';
    }
    return n;
}

static const char *opt(const char *s) { return s[0] ? s : NULL; }

static int64_t parse_ref(const char *s) { return strtoll(s, NULL, 10); }

static uint32_t parse_ifindex(const char *s) { return (uint32_t)strtoll(s, NULL, 10); }

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Adds "KEY=HEXVALUE", or a bare boolean "KEY", to the TXT record. */
static int txt_append(TXTRecordRef *txt, const char *field)
{
    const char *eq = strchr(field, '=');
    size_t klen = eq ? (size_t)(eq - field) : strlen(field);

    char key[256];
    if (klen == 0 || klen >= sizeof(key)) return -1;
    memcpy(key, field, klen);
    key[klen] = '\0';

    if (!eq) return TXTRecordSetValue(txt, key, 0, NULL) == kDNSServiceErr_NoError ? 0 : -1;

    const char *hex = eq + 1;
    size_t hlen = strlen(hex);
    if (hlen % 2 != 0 || hlen / 2 > 255) return -1;

    unsigned char val[256];
    for (size_t i = 0; i < hlen; i += 2) {
        int hi = hexval(hex[i]), lo = hexval(hex[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        val[i / 2] = (unsigned char)((hi << 4) | lo);
    }

    return TXTRecordSetValue(txt, key, (uint8_t)(hlen / 2), val) == kDNSServiceErr_NoError
               ? 0
               : -1;
}

/* Builds a TXT record from fields f[first..n). On failure the TXTRecordRef
 * has already been deallocated. */
static int build_txt(TXTRecordRef *txt, unsigned char *buf, size_t buflen, char **f, int first,
                     int n)
{
    TXTRecordCreate(txt, (uint16_t)buflen, buf);
    for (int i = first; i < n; i++) {
        if (f[i][0] == '\0') continue;
        if (txt_append(txt, f[i]) != 0) {
            TXTRecordDeallocate(txt);
            return -1;
        }
    }
    return 0;
}

static const char *ifname_of(uint32_t ifindex, char *buf)
{
    if (ifindex == 0 || if_indextoname(ifindex, buf) == NULL) return NULL;
    return buf;
}

/* ---------- registration ---------- */

static void DNSSD_API register_cb(DNSServiceRef sdRef, DNSServiceFlags flags,
                                  DNSServiceErrorType err, const char *name,
                                  const char *regtype, const char *domain, void *ctx)
{
    (void)sdRef;
    int64_t ref = (int64_t)(intptr_t)ctx;

    if (err != kDNSServiceErr_NoError) {
        reply_err(ref, (int)err);
        return;
    }
    /* Without the Add flag the daemon is reporting the name lost. */
    if (!(flags & kDNSServiceFlagsAdd)) {
        reply_err(ref, kDNSServiceErr_NameConflict);
        return;
    }

    out_start("ok");
    out_fmt("%lld", (long long)ref);
    out_str(name);
    out_str(regtype);
    out_str(domain);
    out_send(ref);
}

static void DNSSD_API record_cb(DNSServiceRef sdRef, DNSRecordRef recRef,
                                DNSServiceFlags flags, DNSServiceErrorType err, void *ctx)
{
    (void)sdRef;
    (void)recRef;
    (void)flags;
    int64_t ref = (int64_t)(intptr_t)ctx;

    if (err == kDNSServiceErr_NoError)
        reply_ok(ref);
    else
        reply_err(ref, (int)err);
}

static void cmd_register(char **f, int n)
{
    if (n < 9) return;

    int64_t ref = parse_ref(f[1]);
    uint32_t ifindex = parse_ifindex(f[2]);
    DNSServiceFlags flags = kDNSServiceFlagsShareConnection;
    if (strchr(f[3], 'n')) flags |= kDNSServiceFlagsNoAutoRename;
    uint16_t port = (uint16_t)strtoul(f[8], NULL, 10);

    unsigned char txtbuf[MAX_TXT];
    TXTRecordRef txt;
    if (build_txt(&txt, txtbuf, sizeof(txtbuf), f, 9, n) != 0) {
        reply_err(ref, kDNSServiceErr_BadParam);
        return;
    }

    entry_t *e = entry_claim(ref);
    if (!e) {
        TXTRecordDeallocate(&txt);
        return;
    }

    DNSServiceRef sd = g_conn;
    DNSServiceErrorType err = DNSServiceRegister(
        &sd, flags, ifindex, opt(f[4]), f[5], opt(f[6]), opt(f[7]), htons(port),
        TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), register_cb, (void *)(intptr_t)ref);
    TXTRecordDeallocate(&txt);
    entry_started(e, ref, err, sd);
}

static void cmd_record(char **f, int n)
{
    if (n < 6) return;

    int64_t ref = parse_ref(f[1]);
    uint32_t ifindex = parse_ifindex(f[2]);
    const char *hostname = f[3];
    const char *ip = f[4];
    uint32_t ttl = (uint32_t)strtoul(f[5], NULL, 10);

    int v6 = strchr(ip, ':') != NULL;
    unsigned char raw[16];
    if (inet_pton(v6 ? AF_INET6 : AF_INET, ip, raw) != 1) {
        reply_err(ref, kDNSServiceErr_BadParam);
        return;
    }

    entry_t *e = entry_claim(ref);
    if (!e) return;

    DNSRecordRef rec = NULL;
    DNSServiceErrorType err = DNSServiceRegisterRecord(
        g_conn, &rec, kDNSServiceFlagsUnique, ifindex, hostname,
        v6 ? kDNSServiceType_AAAA : kDNSServiceType_A, kDNSServiceClass_IN, v6 ? 16 : 4, raw, ttl,
        record_cb, (void *)(intptr_t)ref);

    if (err != kDNSServiceErr_NoError) {
        entry_free(e);
        reply_err(ref, (int)err);
        return;
    }
    e->is_record = 1;
    e->record_ref = rec;
}

/* DNSServiceUpdateRecord with a NULL RecordRef targets the registration's
 * primary TXT record. */
static void cmd_update(char **f, int n)
{
    if (n < 2) return;

    int64_t ref = parse_ref(f[1]);
    entry_t *e = entry_find(ref);
    if (!e || e->is_record || !e->sd_ref) {
        reply_err(ref, kDNSServiceErr_BadReference);
        return;
    }

    unsigned char txtbuf[MAX_TXT];
    TXTRecordRef txt;
    if (build_txt(&txt, txtbuf, sizeof(txtbuf), f, 2, n) != 0) {
        reply_err(ref, kDNSServiceErr_BadParam);
        return;
    }

    DNSServiceErrorType err = DNSServiceUpdateRecord(e->sd_ref, NULL, 0, TXTRecordGetLength(&txt),
                                                     TXTRecordGetBytesPtr(&txt), 0 /* ttl */);
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError)
        reply_err(ref, (int)err);
    else
        reply_ok(ref);
}

/* ---------- queries ---------- */

static void DNSSD_API browse_cb(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifindex,
                                DNSServiceErrorType err, const char *name, const char *regtype,
                                const char *domain, void *ctx)
{
    (void)sdRef;
    int64_t ref = (int64_t)(intptr_t)ctx;

    if (err != kDNSServiceErr_NoError) {
        reply_err(ref, (int)err);
        return;
    }

    char ifbuf[IF_NAMESIZE];
    out_start("browse");
    out_fmt("%lld", (long long)ref);
    out_str((flags & kDNSServiceFlagsAdd) ? "add" : "rmv");
    out_fmt("%u", ifindex);
    out_str(ifname_of(ifindex, ifbuf));
    out_str(name);
    out_str(regtype);
    out_str(domain);
    out_str((flags & kDNSServiceFlagsMoreComing) ? "1" : "0");
    out_send(ref);
}

static void DNSSD_API resolve_cb(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifindex,
                                 DNSServiceErrorType err, const char *fullname,
                                 const char *hosttarget, uint16_t port, uint16_t txt_len,
                                 const unsigned char *txt, void *ctx)
{
    (void)sdRef;
    (void)fullname;
    int64_t ref = (int64_t)(intptr_t)ctx;

    if (err != kDNSServiceErr_NoError) {
        reply_err(ref, (int)err);
        return;
    }

    char ifbuf[IF_NAMESIZE];
    out_start("resolved");
    out_fmt("%lld", (long long)ref);
    out_fmt("%u", ifindex);
    out_str(ifname_of(ifindex, ifbuf));
    out_str(hosttarget);
    out_fmt("%u", (unsigned)ntohs(port));
    out_hex(txt, txt_len);
    out_str((flags & kDNSServiceFlagsMoreComing) ? "1" : "0");
    out_send(ref);
}

static void DNSSD_API addrinfo_cb(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifindex,
                                  DNSServiceErrorType err, const char *hostname,
                                  const struct sockaddr *address, uint32_t ttl, void *ctx)
{
    (void)sdRef;
    int64_t ref = (int64_t)(intptr_t)ctx;

    /* A negative answer, only delivered when asked for. The query carries on. */
    if (err == kDNSServiceErr_NoSuchRecord) return;
    if (err != kDNSServiceErr_NoError) {
        reply_err(ref, (int)err);
        return;
    }
    if (!address) return;

    char ip[INET6_ADDRSTRLEN];
    if (address->sa_family == AF_INET)
        inet_ntop(AF_INET, &((const struct sockaddr_in *)address)->sin_addr, ip, sizeof(ip));
    else if (address->sa_family == AF_INET6)
        inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)address)->sin6_addr, ip, sizeof(ip));
    else
        return;

    char ifbuf[IF_NAMESIZE];
    out_start("addr");
    out_fmt("%lld", (long long)ref);
    out_str((flags & kDNSServiceFlagsAdd) ? "add" : "rmv");
    out_fmt("%u", ifindex);
    out_str(ifname_of(ifindex, ifbuf));
    out_str(hostname);
    out_str(ip);
    out_fmt("%u", ttl);
    out_str((flags & kDNSServiceFlagsMoreComing) ? "1" : "0");
    out_send(ref);
}

static void cmd_browse(char **f, int n)
{
    if (n < 5) return;

    int64_t ref = parse_ref(f[1]);
    entry_t *e = entry_claim(ref);
    if (!e) return;

    DNSServiceRef sd = g_conn;
    DNSServiceErrorType err =
        DNSServiceBrowse(&sd, kDNSServiceFlagsShareConnection, parse_ifindex(f[2]), f[3],
                         opt(f[4]), browse_cb, (void *)(intptr_t)ref);
    entry_started(e, ref, err, sd);
}

static void cmd_resolve(char **f, int n)
{
    if (n < 6) return;

    int64_t ref = parse_ref(f[1]);
    entry_t *e = entry_claim(ref);
    if (!e) return;

    DNSServiceRef sd = g_conn;
    DNSServiceErrorType err =
        DNSServiceResolve(&sd, kDNSServiceFlagsShareConnection, parse_ifindex(f[2]), f[3], f[4],
                          f[5], resolve_cb, (void *)(intptr_t)ref);
    entry_started(e, ref, err, sd);
}

static void cmd_addrinfo(char **f, int n)
{
    if (n < 5) return;

    int64_t ref = parse_ref(f[1]);
    DNSServiceProtocol protocols = 0;
    if (strchr(f[3], '4')) protocols |= kDNSServiceProtocol_IPv4;
    if (strchr(f[3], '6')) protocols |= kDNSServiceProtocol_IPv6;

    entry_t *e = entry_claim(ref);
    if (!e) return;

    DNSServiceRef sd = g_conn;
    DNSServiceErrorType err =
        DNSServiceGetAddrInfo(&sd, kDNSServiceFlagsShareConnection, parse_ifindex(f[2]),
                              protocols, f[4], addrinfo_cb, (void *)(intptr_t)ref);
    entry_started(e, ref, err, sd);
}

static void handle_frame(char *line)
{
    static char *f[MAX_FIELDS];
    int n = split_fields(line, f, MAX_FIELDS);

    if (strcmp(f[0], "register") == 0)
        cmd_register(f, n);
    else if (strcmp(f[0], "record") == 0)
        cmd_record(f, n);
    else if (strcmp(f[0], "update") == 0)
        cmd_update(f, n);
    else if (strcmp(f[0], "browse") == 0)
        cmd_browse(f, n);
    else if (strcmp(f[0], "resolve") == 0)
        cmd_resolve(f, n);
    else if (strcmp(f[0], "addrinfo") == 0)
        cmd_addrinfo(f, n);
    else if (strcmp(f[0], "remove") == 0 && n >= 2)
        entry_free(entry_find(parse_ref(f[1])));
}

/* ---------- main loop ---------- */

int main(void)
{
    static unsigned char frame[MAX_FRAME + 1];

    DNSServiceErrorType err = DNSServiceCreateConnection(&g_conn);
    if (err != kDNSServiceErr_NoError) fatal((int)err);
    write_frame("up", 2);

    int dns_fd = DNSServiceRefSockFD(g_conn);

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(STDIN_FILENO, &rfds);
        FD_SET(dns_fd, &rfds);
        int maxfd = dns_fd > STDIN_FILENO ? dns_fd : STDIN_FILENO;

        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            return 1;
        }

        if (FD_ISSET(dns_fd, &rfds)) {
            /* A dead daemon surfaces here. Exit and let Elixir replay. */
            err = DNSServiceProcessResult(g_conn);
            if (err != kDNSServiceErr_NoError) fatal((int)err);
        }

        if (FD_ISSET(STDIN_FILENO, &rfds)) {
            unsigned char hdr[4];
            if (read_exact(hdr, 4) <= 0) return 0;

            size_t len = ((size_t)hdr[0] << 24) | ((size_t)hdr[1] << 16) |
                         ((size_t)hdr[2] << 8) | (size_t)hdr[3];
            if (len > MAX_FRAME) return 1;

            if (read_exact(frame, len) <= 0) return 0;
            frame[len] = '\0';
            handle_frame((char *)frame);
        }
    }
}
