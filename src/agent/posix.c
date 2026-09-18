/* Narrow POSIX metadata shim. Zig 0.16 cannot translate musl's stat bitfields. */
#include <stdint.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netdb.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
struct dragontools_metadata { uint64_t uid, gid, mode, nlink; };
int dragontools_file_metadata(int fd, struct dragontools_metadata *out) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    out->uid = st.st_uid;
    out->gid = st.st_gid;
    out->mode = st.st_mode;
    out->nlink = st.st_nlink;
    return 0;
}

/* This one-shot helper has no background tasks. A process deadline also bounds
 * libc DNS, whose blocking resolver API has no per-call timeout. The signal
 * handler only performs the async-signal-safe _exit with a fixed semantic code. */
static volatile sig_atomic_t deadline_code = 92;
static void timed_out(int signo) { (void)signo; _exit(deadline_code); }
void dragontools_network_deadline(int code) {
    deadline_code = code;
    signal(SIGALRM, timed_out);
    alarm(4);
}
void dragontools_network_cancel(void) { alarm(0); }
int dragontools_connect(const char *host, const char *port, int *result) {
    struct addrinfo hints = {0}, *addresses = NULL, *item;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    dragontools_network_deadline(91);
    if (getaddrinfo(host, port, &hints, &addresses) != 0) {
        dragontools_network_cancel();
        return 91;
    }
    dragontools_network_deadline(92);
    int fd = -1;
    /* Prefer A records for the managed IPv4 listener; retain IPv6 fallback. */
    for (int pass = 0; pass < 2 && fd < 0; ++pass) {
        unsigned count = 0;
        for (item = addresses; item && count < 16; item = item->ai_next, ++count) {
            if ((item->ai_family == AF_INET) != (pass == 0)) continue;
            if (item->ai_family != AF_INET && item->ai_family != AF_INET6) continue;
            fd = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
            if (fd < 0) continue;
            if (connect(fd, item->ai_addr, item->ai_addrlen) == 0) break;
            close(fd);
            fd = -1;
        }
    }
    freeaddrinfo(addresses);
    dragontools_network_cancel();
    if (fd < 0) return 92;
    *result = fd;
    return 0;
}
int dragontools_tls_send(void *context, const unsigned char *bytes, size_t size) {
    int fd = ((mbedtls_net_context *) context)->fd;
    ssize_t count = send(fd, bytes, size, MSG_NOSIGNAL);
    if (count >= 0) return (int) count;
    return errno == EINTR ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_NET_SEND_FAILED;
}
