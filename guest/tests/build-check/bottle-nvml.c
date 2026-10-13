/*
 * bottle-nvml: the Mac's GPU numbers for Steam's performance monitor.
 *
 * Steam's in-game overlay (steamrtarm64/gameoverlayui.so, the arm64 client's) shows GPU load,
 * GPU memory and GPU temperature from one of three places: NVIDIA's NVML (libnvidia-ml.so.1,
 * loaded when it's there), AMD's sysfs (gpu_busy_percent) or hwmon. The VM's GPU is virtio-gpu
 * (Venus, drawing on the Mac's GPU through KosmicKrisp), which has none of those, so the monitor
 * shows no GPU numbers. This library answers NVML's calls the monitor makes, with what the Mac
 * measures: the SteamOS Bottle app samples its GPU once a second (load and memory from the GPU
 * driver's statistics, temperature from the chip's sensors) and sends it to the VM's screen
 * server, which writes /dev/shm/steamos-bottle-host-stats. Numbers older than 5 s count as
 * none (the app closed): the calls then say "not supported", as NVML does for a missing sensor.
 *
 * Only Steam's own processes find it: steam-arm64 links it into Steam's library folder
 * (lib/aarch64-linux-gnu), not into the system's. The functions are the ones gameoverlayui.so
 * asks for (nvmlInit_v2, nvmlDeviceGetCount_v2, nvmlDeviceGetHandleByIndex_v2, nvmlDeviceGetName,
 * nvmlDeviceGetUtilizationRates, nvmlDeviceGetMemoryInfo, nvmlDeviceGetTemperature,
 * nvmlShutdown), plus a few others programs commonly try first.
 *
 *   cc -O2 -fPIC -shared -Wl,-soname,libnvidia-ml.so.1 -o libnvidia-ml.so.1 bottle-nvml.c
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define EXPORT __attribute__((visibility("default")))

typedef int nvmlReturn_t;
enum { NVML_SUCCESS = 0, NVML_ERROR_UNINITIALIZED = 1, NVML_ERROR_INVALID_ARGUMENT = 2,
       NVML_ERROR_NOT_SUPPORTED = 3, NVML_ERROR_INSUFFICIENT_SIZE = 7, NVML_ERROR_NOT_FOUND = 6 };
typedef struct nvmlDevice_st *nvmlDevice_t;
typedef struct { unsigned int gpu, memory; } nvmlUtilization_t;
typedef struct { unsigned long long total, free, used; } nvmlMemory_t;

static struct nvmlDevice_st { int unused; } g_dev;
static int g_init;

#ifndef STATS_FILE
#define STATS_FILE "/dev/shm/steamos-bottle-host-stats"
#endif

/* The Mac's numbers: "key value" lines. Fresh (written in the last 5 s) or nothing. */
typedef struct { int ok; double gpu, temp; double mem_used_mb, mem_total_mb; char name[96]; } Stats;

static Stats read_stats(void) {
    Stats s = {0};
    snprintf(s.name, sizeof s.name, "Mac GPU");
    s.gpu = s.temp = -1;
    const char *path = getenv("BOTTLE_HOST_STATS");
    FILE *f = fopen(path && *path ? path : STATS_FILE, "r");
    if (!f) return s;
    char line[160];
    double t = 0;
    while (fgets(line, sizeof line, f)) {
        char *v = strchr(line, ' ');
        if (!v) continue;
        *v++ = 0;
        v[strcspn(v, "\n")] = 0;
        if (!strcmp(line, "time")) t = atof(v);
        else if (!strcmp(line, "gpu_util")) s.gpu = atof(v);
        else if (!strcmp(line, "gpu_temp")) s.temp = atof(v);
        else if (!strcmp(line, "gpu_mem_used_mb")) s.mem_used_mb = atof(v);
        else if (!strcmp(line, "gpu_mem_total_mb")) s.mem_total_mb = atof(v);
        else if (!strcmp(line, "gpu_name") && *v) snprintf(s.name, sizeof s.name, "%s", v);
    }
    fclose(f);
    s.ok = t > 0 && (double)time(NULL) - t < 5;
    return s;
}

EXPORT nvmlReturn_t nvmlInit_v2(void) { g_init = 1; return NVML_SUCCESS; }
EXPORT nvmlReturn_t nvmlInit(void) { return nvmlInit_v2(); }
EXPORT nvmlReturn_t nvmlInitWithFlags(unsigned int flags) { (void)flags; return nvmlInit_v2(); }
EXPORT nvmlReturn_t nvmlShutdown(void) { g_init = 0; return NVML_SUCCESS; }

EXPORT const char *nvmlErrorString(nvmlReturn_t r) {
    switch (r) {
    case NVML_SUCCESS: return "Success";
    case NVML_ERROR_UNINITIALIZED: return "Uninitialized";
    case NVML_ERROR_INVALID_ARGUMENT: return "Invalid Argument";
    case NVML_ERROR_NOT_SUPPORTED: return "Not Supported";
    default: return "Unknown Error";
    }
}

EXPORT nvmlReturn_t nvmlSystemGetDriverVersion(char *v, unsigned int n) {
    if (!v || n < 2) return NVML_ERROR_INVALID_ARGUMENT;
    snprintf(v, n, "SteamOS Bottle");
    return NVML_SUCCESS;
}

EXPORT nvmlReturn_t nvmlDeviceGetCount_v2(unsigned int *count) {
    if (!g_init) return NVML_ERROR_UNINITIALIZED;
    if (!count) return NVML_ERROR_INVALID_ARGUMENT;
    *count = 1;
    return NVML_SUCCESS;
}
EXPORT nvmlReturn_t nvmlDeviceGetCount(unsigned int *count) { return nvmlDeviceGetCount_v2(count); }

EXPORT nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(unsigned int i, nvmlDevice_t *dev) {
    if (!g_init) return NVML_ERROR_UNINITIALIZED;
    if (!dev || i != 0) return NVML_ERROR_INVALID_ARGUMENT;
    *dev = &g_dev;
    return NVML_SUCCESS;
}
EXPORT nvmlReturn_t nvmlDeviceGetHandleByIndex(unsigned int i, nvmlDevice_t *dev) { return nvmlDeviceGetHandleByIndex_v2(i, dev); }

EXPORT nvmlReturn_t nvmlDeviceGetName(nvmlDevice_t dev, char *name, unsigned int n) {
    if (dev != &g_dev || !name || !n) return NVML_ERROR_INVALID_ARGUMENT;
    Stats s = read_stats();
    if (strlen(s.name) + 1 > n) return NVML_ERROR_INSUFFICIENT_SIZE;
    snprintf(name, n, "%s", s.name);
    return NVML_SUCCESS;
}

EXPORT nvmlReturn_t nvmlDeviceGetUtilizationRates(nvmlDevice_t dev, nvmlUtilization_t *u) {
    if (dev != &g_dev || !u) return NVML_ERROR_INVALID_ARGUMENT;
    Stats s = read_stats();
    if (!s.ok || s.gpu < 0) return NVML_ERROR_NOT_SUPPORTED;
    u->gpu = (unsigned)(s.gpu < 0 ? 0 : s.gpu > 100 ? 100 : s.gpu + 0.5);
    u->memory = s.mem_total_mb > 0 ? (unsigned)(s.mem_used_mb * 100 / s.mem_total_mb + 0.5) : 0;
    return NVML_SUCCESS;
}

EXPORT nvmlReturn_t nvmlDeviceGetMemoryInfo(nvmlDevice_t dev, nvmlMemory_t *m) {
    if (dev != &g_dev || !m) return NVML_ERROR_INVALID_ARGUMENT;
    Stats s = read_stats();
    if (!s.ok || s.mem_total_mb <= 0) return NVML_ERROR_NOT_SUPPORTED;
    unsigned long long mb = 1024ull * 1024;
    m->total = (unsigned long long)s.mem_total_mb * mb;
    m->used = (unsigned long long)s.mem_used_mb * mb;
    if (m->used > m->total) m->used = m->total;
    m->free = m->total - m->used;
    return NVML_SUCCESS;
}

EXPORT nvmlReturn_t nvmlDeviceGetTemperature(nvmlDevice_t dev, int sensor, unsigned int *temp) {
    if (dev != &g_dev || !temp) return NVML_ERROR_INVALID_ARGUMENT;
    if (sensor != 0) return NVML_ERROR_NOT_SUPPORTED;   /* NVML_TEMPERATURE_GPU */
    Stats s = read_stats();
    if (!s.ok || s.temp <= 0) return NVML_ERROR_NOT_SUPPORTED;
    *temp = (unsigned)(s.temp + 0.5);
    return NVML_SUCCESS;
}
