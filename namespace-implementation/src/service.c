/*
 * service.c — Lightweight HTTP microservice for namespace-based benchmarking
 *
 * Behavior:
 *   - Listens on port 8080
 *   - If NEXT_SERVICE env var is set (e.g. "http://10.0.1.3:8080"):
 *       forwards request to next service, prepends "-> " to response
 *   - If NEXT_SERVICE is unset/empty:
 *       responds with "service-c\n" (terminal service)
 *
 * Replicates the Go microservice logic from the Kind-based implementation.
 * Uses only POSIX sockets — no external dependencies.
 *
 * Compile: gcc -static -o service service.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#define PORT 8080
#define BUF_SIZE 8192
#define BACKLOG 128

static const char *next_service = NULL;
static const char *service_name = NULL;

/* Parse host and port from a URL like "http://10.0.1.3:8080" */
static int parse_url(const char *url, char *host, int *port, char *path) {
    /* skip "http://" */
    const char *p = url;
    if (strncmp(p, "http://", 7) == 0)
        p += 7;

    /* extract host */
    const char *colon = strchr(p, ':');
    const char *slash = strchr(p, '/');

    if (colon && (!slash || colon < slash)) {
        int hlen = colon - p;
        strncpy(host, p, hlen);
        host[hlen] = '\0';
        *port = atoi(colon + 1);
        if (slash) {
            /* strip port from path start */
            const char *path_start = strchr(colon + 1, '/');
            if (path_start)
                strcpy(path, path_start);
            else
                strcpy(path, "/");
        } else {
            strcpy(path, "/");
        }
    } else if (slash) {
        int hlen = slash - p;
        strncpy(host, p, hlen);
        host[hlen] = '\0';
        *port = 80;
        strcpy(path, slash);
    } else {
        strcpy(host, p);
        *port = 80;
        strcpy(path, "/");
    }
    return 0;
}

/* Make HTTP GET to next service, return response body length or -1 */
static int forward_request(const char *url, char *resp_body, int resp_max) {
    char host[256], path[256];
    int port;

    if (parse_url(url, host, &port, path) < 0) {
        fprintf(stderr, "[%s] forward: URL parse failed for '%s'\n",
            service_name ? service_name : "?", url);
        return -1;
    }

    fprintf(stderr, "[%s] forward: connecting to %s:%d%s\n",
        service_name ? service_name : "?", host, port, path);

    /* Resolve host */
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        fprintf(stderr, "[%s] forward: inet_pton failed, trying gethostbyname\n",
            service_name ? service_name : "?");
        struct hostent *he = gethostbyname(host);
        if (!he) {
            fprintf(stderr, "[%s] forward: DNS resolution failed for '%s'\n",
                service_name ? service_name : "?", host);
            return -1;
        }
        memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        fprintf(stderr, "[%s] forward: socket() failed: %s\n",
            service_name ? service_name : "?", strerror(errno));
        return -1;
    }

    /* Set connect timeout */
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[%s] forward: connect to %s:%d failed: %s\n",
            service_name ? service_name : "?", host, port, strerror(errno));
        close(sock);
        return -1;
    }

    fprintf(stderr, "[%s] forward: connected to %s:%d\n",
        service_name ? service_name : "?", host, port);

    /* Send HTTP GET */
    char req[512];
    int reqlen = snprintf(req, sizeof(req),
        "GET %s HTTP/1.0\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
        path, host, port);
    if (send(sock, req, reqlen, 0) < 0) {
        fprintf(stderr, "[%s] forward: send failed: %s\n",
            service_name ? service_name : "?", strerror(errno));
        close(sock);
        return -1;
    }

    /* Read response */
    char raw[BUF_SIZE];
    int total = 0, n;
    while ((n = recv(sock, raw + total, sizeof(raw) - total - 1, 0)) > 0)
        total += n;
    raw[total] = '\0';
    close(sock);

    fprintf(stderr, "[%s] forward: received %d bytes from %s:%d\n",
        service_name ? service_name : "?", total, host, port);

    /* Find body after \r\n\r\n */
    char *body = strstr(raw, "\r\n\r\n");
    if (!body) {
        fprintf(stderr, "[%s] forward: no HTTP body found in response\n",
            service_name ? service_name : "?");
        return -1;
    }
    body += 4;

    int bodylen = total - (body - raw);
    if (bodylen >= resp_max) bodylen = resp_max - 1;
    memcpy(resp_body, body, bodylen);
    resp_body[bodylen] = '\0';

    /* Strip trailing whitespace */
    while (bodylen > 0 && (resp_body[bodylen-1] == '\n' || resp_body[bodylen-1] == '\r'))
        resp_body[--bodylen] = '\0';

    fprintf(stderr, "[%s] forward: body='%s' (%d bytes)\n",
        service_name ? service_name : "?", resp_body, bodylen);

    return bodylen;
}

/* Handle a single client connection */
static void handle_client(int client_fd) {
    char req[BUF_SIZE];
    int n = recv(client_fd, req, sizeof(req) - 1, 0);
    if (n <= 0) { close(client_fd); return; }
    req[n] = '\0';

    char response_body[BUF_SIZE];

    if (next_service && next_service[0] != '\0') {
        /* Forward to next service */
        char downstream[BUF_SIZE - 8];
        int len = forward_request(next_service, downstream, sizeof(downstream));
        if (len < 0) {
            snprintf(response_body, sizeof(response_body),
                "Error forwarding to %s", next_service);
        } else {
            snprintf(response_body, sizeof(response_body),
                "-> %s", downstream);
        }
    } else {
        /* Terminal service */
        snprintf(response_body, sizeof(response_body), "service-c");
    }

    /* Send HTTP response */
    char http_response[BUF_SIZE];
    int resp_len = snprintf(http_response, sizeof(http_response),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        (int)strlen(response_body), response_body);

    send(client_fd, http_response, resp_len, 0);
    close(client_fd);
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    next_service = getenv("NEXT_SERVICE");
    service_name = getenv("SERVICE_NAME");
    if (!service_name) service_name = "service";

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }

    if (listen(server_fd, BACKLOG) < 0) {
        perror("listen");
        return 1;
    }

    fprintf(stderr, "[%s] Listening on :%d (NEXT_SERVICE=%s)\n",
        service_name, PORT,
        (next_service && next_service[0]) ? next_service : "(none)");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        /* Fork to handle concurrently */
        pid_t pid = fork();
        if (pid == 0) {
            /* Child */
            close(server_fd);
            handle_client(client_fd);
            _exit(0);
        } else {
            /* Parent */
            close(client_fd);
        }
    }

    close(server_fd);
    return 0;
}
