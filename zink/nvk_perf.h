/* SPDX-License-Identifier: MIT */
#ifndef NVK_ZINK_EXPERIMENTAL_PERF_H
#define NVK_ZINK_EXPERIMENTAL_PERF_H

/* Opt-in wall-clock diagnostics only. No GPU synchronization is changed. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct nvk_perf_stats {
    unsigned count;
    double totals[4];
    double maxima[4];
};

static inline int nvk_perf_enabled(void)
{
    const char *value = getenv("NVKZINK_PROFILE");
    return value && value[0] && strcmp(value, "0") != 0;
}

static inline uint64_t nvk_perf_clock(void)
{
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static inline double nvk_perf_ms(uint64_t begin, uint64_t end)
{
    return end >= begin ? (double)(end - begin) / 1000000.0 : 0.0;
}

static inline void nvk_perf_log(const char *line)
{
    fprintf(stderr, "[NVK-PERF %ld] %s\n", (long)getpid(), line);
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char path[1024];
    int n = snprintf(path, sizeof(path), "%s/Library/Logs/NVKZinkProfile-%ld.log",
                     home, (long)getpid());
    if (n < 0 || (size_t)n >= sizeof(path)) return;
    FILE *log = fopen(path, "a");
    if (log) {
        fprintf(log, "[NVK-PERF %ld] %s\n", (long)getpid(), line);
        fclose(log);
    }
}

/* Four numeric slots allow allocation-free per-frame updates; print once/120. */
static inline void nvk_perf_record(struct nvk_perf_stats *stats,
                                   const char *stage, unsigned metrics,
                                   const char *const labels[4],
                                   const double values[4])
{
    if (metrics > 4) return;
    for (unsigned i = 0; i < metrics; ++i) {
        stats->totals[i] += values[i];
        if (stats->maxima[i] < values[i]) stats->maxima[i] = values[i];
    }
    if (++stats->count < 120) return;
    char message[512];
    int len = snprintf(message, sizeof(message), "%s frames=%u", stage, stats->count);
    for (unsigned i = 0; i < metrics && len >= 0 && (size_t)len < sizeof(message); ++i) {
        int appended = snprintf(message + len, sizeof(message) - (size_t)len,
                                " %s_avg=%.3fms %s_max=%.3fms",
                                labels[i], stats->totals[i] / stats->count,
                                labels[i], stats->maxima[i]);
        if (appended < 0) break;
        len += appended;
    }
    if (len >= 0) nvk_perf_log(message);
    memset(stats, 0, sizeof(*stats));
}

#endif
