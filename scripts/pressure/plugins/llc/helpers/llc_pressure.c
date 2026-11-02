#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;

struct worker_config {
    size_t bytes;
    size_t stride;
    unsigned int seed;
};

static void handle_signal(int signo) {
    (void)signo;
    g_stop = 1;
}

static void *idle_worker(void *arg) {
    (void)arg;
    while (!g_stop) {
        sleep(1);
    }
    return NULL;
}

static void *pressure_worker(void *arg) {
    struct worker_config *cfg = (struct worker_config *)arg;
    size_t line_count = 0;
    size_t idx = 0;
    size_t next = 0;
    uint8_t *buffer = NULL;
    volatile uint64_t sink = 0;

    if (cfg->bytes == 0) {
        return idle_worker(NULL);
    }

    if (cfg->stride == 0) {
        cfg->stride = 64;
    }

    if (posix_memalign((void **)&buffer, 64, cfg->bytes) != 0) {
        perror("posix_memalign");
        return NULL;
    }
    memset(buffer, 0, cfg->bytes);

    line_count = cfg->bytes / cfg->stride;
    if (line_count == 0) {
        line_count = 1;
    }

    while (!g_stop) {
        next = rand_r(&cfg->seed) % line_count;
        idx = next * cfg->stride;
        buffer[idx] ^= (uint8_t)(idx & 0xff);
        sink += buffer[idx];
    }

    if (sink == UINT64_MAX) {
        fprintf(stderr, "unexpected sink rollover\n");
    }

    free(buffer);
    return NULL;
}

static unsigned long parse_u64(const char *label, const char *value) {
    char *end = NULL;
    unsigned long parsed = 0;

    errno = 0;
    parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        fprintf(stderr, "invalid %s: %s\n", label, value);
        exit(2);
    }
    return parsed;
}

int main(int argc, char **argv) {
    unsigned long working_set_mb = 0;
    unsigned long workers = 1;
    unsigned long stride_bytes = 64;
    pthread_t *threads = NULL;
    struct worker_config *configs = NULL;
    size_t worker_index = 0;
    size_t bytes_per_worker = 0;
    struct sigaction sa;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--working-set-mb") == 0 && i + 1 < argc) {
            working_set_mb = parse_u64("working-set-mb", argv[++i]);
        } else if (strcmp(argv[i], "--workers") == 0 && i + 1 < argc) {
            workers = parse_u64("workers", argv[++i]);
        } else if (strcmp(argv[i], "--stride-bytes") == 0 && i + 1 < argc) {
            stride_bytes = parse_u64("stride-bytes", argv[++i]);
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        }
    }

    if (workers == 0) {
        workers = 1;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    threads = calloc(workers, sizeof(*threads));
    configs = calloc(workers, sizeof(*configs));
    if (threads == NULL || configs == NULL) {
        perror("calloc");
        return 2;
    }

    bytes_per_worker = (size_t)(working_set_mb * 1024UL * 1024UL) / workers;
    if (working_set_mb > 0 && bytes_per_worker < 4096) {
        bytes_per_worker = 4096;
    }

    for (worker_index = 0; worker_index < workers; worker_index++) {
        configs[worker_index].bytes = bytes_per_worker;
        configs[worker_index].stride = (size_t)stride_bytes;
        configs[worker_index].seed = (unsigned int)(time(NULL) ^ (worker_index * 2654435761u));
        if (pthread_create(&threads[worker_index], NULL,
                working_set_mb == 0 ? idle_worker : pressure_worker,
                &configs[worker_index]) != 0) {
            perror("pthread_create");
            g_stop = 1;
            break;
        }
    }

    for (worker_index = 0; worker_index < workers; worker_index++) {
        if (threads[worker_index] != 0) {
            pthread_join(threads[worker_index], NULL);
        }
    }

    free(configs);
    free(threads);
    return 0;
}

