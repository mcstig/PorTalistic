/*
 * VK_LAYER_BOTTLE_cpu_present
 *
 * Gives Vulkan devices that have no VK_KHR_swapchain (Mesa Venus on a macOS
 * host: no dma-buf, so Venus turns WSI off) a working X11 swapchain:
 *
 *   app renders into ordinary device-local VkImages (on the GPU, via Venus)
 *   -> on present: vkCmdCopyImageToBuffer into a host-visible buffer
 *   -> CPU copies the pixels into the X window (MIT-SHM, or PutImage fallback)
 *
 * Devices that already have a swapchain (llvmpipe, ...) are passed through untouched.
 *
 * Feature spoofing: DXVK refuses a device that lacks fillModeNonSolid, geometryShader,
 * etc., even though most games never use them (KosmicKrisp lacks several). For DXVK/vkd3d
 * instances on managed devices we report the features in k_fakeable as supported and
 * drop them again in vkCreateDevice. A game that really uses one misrenders that draw.
 * DirectX 12 (vkd3d-proton) also needs single-texel buffer view offsets, which KosmicKrisp
 * doesn't report (Metal wants 16-byte offsets). Reported to vkd3d instances as supported: with
 * no VK_EXT_descriptor_buffer (Venus has none; hidden from vkd3d if a driver has it) vkd3d
 * always uses its "typed offset buffer", which starts every typed view at the start of its
 * resource and adds the element offset in the shader, so the views it creates stay aligned.
 * Views that aren't (a buffer UAV clear at an odd offset) are counted and logged.
 * Same idea for VK_EXT_transform_feedback (D3D10/11 stream output; DXVK 2.x requires it):
 * advertised to DXVK/vkd3d, its commands are no-ops. VK_KHR_load_store_op_none is mapped
 * to VK_EXT_load_store_op_none (same enums) for every app.
 *
 * Env:
 *   DISABLE_BOTTLE_PRESENT=1   turn the layer off (loader-level switch)
 *   BOTTLE_PRESENT_FORCE=1     manage every device (testing on a normal GPU/lavapipe)
 *   BOTTLE_PRESENT_DEBUG=1     log to stderr: every 120 frames the frame-time split and what the
 *                              game asked of the GPU (draws, render passes, barriers, new pipelines...)
 *   BOTTLE_PRESENT_SYNC=1      present inside vkQueuePresentKHR instead of on a presenter thread
 *   BOTTLE_PRESENT_SWAP_RB=1   swap red and blue when showing frames (if a game's colours are off)
 *   BOTTLE_FAKE_FEATURES=0     no feature spoofing; =1 spoof for every app (not just DXVK/vkd3d);
 *                              =geometryShader,fillModeNonSolid  spoof only these
 *   BOTTLE_FAKE_ZINK=1         also spoof for Mesa's zink (OpenGL on Vulkan), as for DXVK; or a list
 *   BOTTLE_TEST_TEXEL_ALIGN=16 (tests) a managed device reports 16-byte texel buffer offsets and
 *                              no descriptor buffers, as Venus on KosmicKrisp does
 *                              as above. Without transform feedback zink offers only OpenGL 2.1 and
 *                              GLES 2.0, without geometry shaders no core profile (3.2+), and Steam's
 *                              interface needs more (bottle steam-gpu on sets it).
 *   BOTTLE_FPS_COUNTER=1-4     the layer's own FPS counter in that corner (off by default: Steam's
 *                              overlay draws Steam's own; 1 top left, 2 top right, 3/4 bottom)
 *   BOTTLE_STEAM_OVERLAY=0     don't bring Steam's in-game overlay into games (see host_overlay)
 *   BOTTLE_OVERLAY_TRACE=0     don't log what Steam's overlay draws (see ov_trace)
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#define VK_USE_PLATFORM_XCB_KHR
#define VK_USE_PLATFORM_XLIB_KHR
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <xcb/xcb.h>
#include <xcb/shm.h>

#include <dirent.h>
#include <dlfcn.h>
#include <link.h>
#include <poll.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

#define LAYER_NAME "VK_LAYER_BOTTLE_cpu_present"
#define EXPORT __attribute__((visibility("default")))
#define MAX_IMAGES 8

/* ------------------------------------------------------------------ logging */

static int g_debug = -1;
static uint32_t g_ov_fw, g_ov_fh;   /* the newest swapchain's size, for the overlay trace (ov_trace) */
static int g_force = -1;

/* Core features DXVK requires that a game only exercises if it asks for them. */
#define FEAT(n) {#n, offsetof(VkPhysicalDeviceFeatures, n)}
static const struct { const char *name; size_t off; } k_fakeable[] = {
    FEAT(fillModeNonSolid), FEAT(geometryShader), FEAT(tessellationShader),
    FEAT(shaderCullDistance), FEAT(shaderClipDistance), FEAT(occlusionQueryPrecise),
    FEAT(multiViewport), FEAT(sampleRateShading), FEAT(dualSrcBlend),
    FEAT(depthBiasClamp), FEAT(depthClamp), FEAT(shaderImageGatherExtended),
    FEAT(independentBlend), FEAT(imageCubeArray), FEAT(multiDrawIndirect),
    FEAT(drawIndirectFirstInstance), FEAT(logicOp), FEAT(vertexPipelineStoresAndAtomics),
    FEAT(fragmentStoresAndAtomics), FEAT(shaderSampledImageArrayDynamicIndexing),
    FEAT(textureCompressionBC), FEAT(shaderInt16), FEAT(shaderInt64),
    FEAT(shaderStorageImageWriteWithoutFormat), FEAT(shaderStorageImageReadWithoutFormat),
};
#undef FEAT
#define N_FAKEABLE (sizeof k_fakeable / sizeof k_fakeable[0])

static int g_fake_mode;      /* -1 auto (DXVK/vkd3d only), 0 off, 1 every app */
static int g_swap_rb;        /* BOTTLE_PRESENT_SWAP_RB */
static int g_no_pace;        /* no pacing lines: Steam's own interface (zink), or BOTTLE_PRESENT_PACE=0 */
static int g_zink;           /* this process is Steam's interface through zink, not a game */
static int g_async_pipes;    /* BOTTLE_SYNC_PIPELINES=0: leave Venus' asynchronous pipeline creation on */
static uint64_t g_fake_mask; /* bit i = k_fakeable[i] may be spoofed */
static unsigned g_test_texel_align; /* BOTTLE_TEST_TEXEL_ALIGN: act like Venus' 16-byte texel offsets */

/* "1" or NULL: every k_fakeable feature; else the comma/space separated names given. */
static uint64_t fake_mask_from(const char *ff) {
    uint64_t all = (N_FAKEABLE >= 64) ? ~0ull : ((1ull << N_FAKEABLE) - 1), m = 0;
    if (!ff || !strcmp(ff, "1")) return all;
    for (size_t i = 0; i < N_FAKEABLE; i++) {
        const char *p = strstr(ff, k_fakeable[i].name);
        size_t len = strlen(k_fakeable[i].name);
        while (p && ((p > ff && p[-1] != ',' && p[-1] != ' ') ||
                     (p[len] && p[len] != ',' && p[len] != ' ')))
            p = strstr(p + 1, k_fakeable[i].name);
        if (p) m |= 1ull << i;
    }
    return m;
}

static void init_env(void) {
    if (g_debug < 0) {
        const char *d = getenv("BOTTLE_PRESENT_DEBUG");
        g_debug = d && *d && *d != '0';
        const char *f = getenv("BOTTLE_PRESENT_FORCE");
        g_force = f && *f && *f != '0';
        const char *pc = getenv("BOTTLE_PRESENT_PACE");
        g_no_pace = pc && *pc == '0';
        const char *sp = getenv("BOTTLE_SYNC_PIPELINES");
        g_async_pipes = sp && *sp == '0';
        const char *rb = getenv("BOTTLE_PRESENT_SWAP_RB");
        g_swap_rb = rb && *rb && *rb != '0';
        const char *ta = getenv("BOTTLE_TEST_TEXEL_ALIGN");
        g_test_texel_align = ta ? (unsigned)strtoul(ta, NULL, 10) : 0;

        const char *ff = getenv("BOTTLE_FAKE_FEATURES");
        g_fake_mode = -1;
        g_fake_mask = fake_mask_from(NULL);
        if (ff && *ff) {
            if (!strcmp(ff, "0")) {
                g_fake_mode = 0;
            } else {
                g_fake_mode = 1;
                g_fake_mask = fake_mask_from(ff);
            }
        }
    }
}

/* Lines carry the time of day, so they line up with the VM's and the Mac's logs. */
static void log_stamp(void) {
    time_t t = time(NULL);
    struct tm tm;
    char b[16];
    strftime(b, sizeof b, "%H:%M:%S", localtime_r(&t, &tm));
    fprintf(stderr, "[bottle-present %s] ", b);
}
#define LOG(...)                            \
    do {                                    \
        if (g_debug > 0) {                  \
            log_stamp();                    \
            fprintf(stderr, __VA_ARGS__);   \
            fputc('\n', stderr);            \
        }                                   \
    } while (0)
/* Always printed: the pacing line every 10 s of play (see pace_frame). */
#define LOGA(...)                           \
    do {                                    \
        log_stamp();                        \
        fprintf(stderr, __VA_ARGS__);       \
        fputc('\n', stderr);                \
    } while (0)

/* ------------------------------------------------------------ tiny registry */

typedef struct Node { void *key; void *val; struct Node *next; } Node;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void map_put(Node **head, void *key, void *val) {
    Node *n = malloc(sizeof *n);
    n->key = key; n->val = val;
    pthread_mutex_lock(&g_lock);
    n->next = *head; *head = n;
    pthread_mutex_unlock(&g_lock);
}

static void *map_get(Node **head, void *key) {
    void *v = NULL;
    pthread_mutex_lock(&g_lock);
    for (Node *n = *head; n; n = n->next)
        if (n->key == key) { v = n->val; break; }
    pthread_mutex_unlock(&g_lock);
    return v;
}

static void *map_del(Node **head, void *key) {
    void *v = NULL;
    pthread_mutex_lock(&g_lock);
    for (Node **p = head; *p; p = &(*p)->next)
        if ((*p)->key == key) { Node *n = *p; v = n->val; *p = n->next; free(n); break; }
    pthread_mutex_unlock(&g_lock);
    return v;
}

static inline void *dkey(const void *dispatchable) { return *(void *const *)dispatchable; }

/* ---------------------------------------------------------------- instance */

typedef struct {
    VkInstance instance;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkDestroyInstance DestroyInstance;
    PFN_vkEnumerateDeviceExtensionProperties EnumerateDeviceExtensionProperties;
    PFN_vkGetPhysicalDeviceProperties GetPhysicalDeviceProperties;
    PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties GetPhysicalDeviceQueueFamilyProperties;
    PFN_vkGetPhysicalDeviceSurfaceSupportKHR GetPhysicalDeviceSurfaceSupportKHR;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR GetPhysicalDeviceSurfaceCapabilitiesKHR;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR GetPhysicalDeviceSurfaceFormatsKHR;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR GetPhysicalDeviceSurfacePresentModesKHR;
    PFN_vkGetPhysicalDeviceSurfaceCapabilities2KHR GetPhysicalDeviceSurfaceCapabilities2KHR;
    PFN_vkGetPhysicalDeviceSurfaceFormats2KHR GetPhysicalDeviceSurfaceFormats2KHR;
    PFN_vkGetPhysicalDevicePresentRectanglesKHR GetPhysicalDevicePresentRectanglesKHR;
    PFN_vkGetPhysicalDeviceXcbPresentationSupportKHR GetPhysicalDeviceXcbPresentationSupportKHR;
    PFN_vkGetPhysicalDeviceXlibPresentationSupportKHR GetPhysicalDeviceXlibPresentationSupportKHR;
    PFN_vkCreateXcbSurfaceKHR CreateXcbSurfaceKHR;
    PFN_vkCreateXlibSurfaceKHR CreateXlibSurfaceKHR;
    PFN_vkDestroySurfaceKHR DestroySurfaceKHR;
    PFN_vkGetPhysicalDeviceFeatures GetPhysicalDeviceFeatures;
    PFN_vkGetPhysicalDeviceFeatures2 GetPhysicalDeviceFeatures2;
    PFN_vkGetPhysicalDeviceFeatures2KHR GetPhysicalDeviceFeatures2KHR;
    PFN_vkGetPhysicalDeviceProperties2 GetPhysicalDeviceProperties2;
    PFN_vkGetPhysicalDeviceProperties2KHR GetPhysicalDeviceProperties2KHR;
    int fake; /* spoof features for this instance (DXVK/vkd3d, zink if asked, or forced) */
    uint64_t fake_mask; /* which k_fakeable features it may spoof */
    int vkd3d; /* the instance is vkd3d-proton's (DirectX 12) */
} InstanceData;

static Node *g_instances;   /* VkInstance -> InstanceData* */
static Node *g_pd_managed;  /* VkPhysicalDevice -> (void*)1 managed / (void*)2 not */
static Node *g_pd_xfb;      /* VkPhysicalDevice -> (void*)1 lacks transform feedback / (void*)2 has it */

#define XFB_EXT "VK_EXT_transform_feedback"
#define LSON_KHR "VK_KHR_load_store_op_none"
#define LSON_EXT "VK_EXT_load_store_op_none"
static Node *g_surfaces;    /* VkSurfaceKHR -> (uintptr_t)window */

static InstanceData *instance_for(const void *dispatchable) {
    /* Physical devices share their instance's dispatch key. Keys are read at lookup
     * time because the loader may install dispatch pointers after creation. */
    InstanceData *found = NULL, *last = NULL;
    void *key = dkey(dispatchable);
    pthread_mutex_lock(&g_lock);
    for (Node *n = g_instances; n; n = n->next) {
        InstanceData *id = n->val;
        last = id;
        if (dkey(id->instance) == key) { found = id; break; }
    }
    pthread_mutex_unlock(&g_lock);
    return found ? found : last;
}

static int pd_managed(InstanceData *id, VkPhysicalDevice pd) {
    void *v = map_get(&g_pd_managed, pd);
    if (v) return v == (void *)1;
    int managed = g_force > 0;
    VkPhysicalDeviceProperties props;
    id->GetPhysicalDeviceProperties(pd, &props);
    if (strstr(props.deviceName, "Venus")) managed = 1;
    LOG("device '%s': %s", props.deviceName, managed ? "managed (CPU-copy swapchain)" : "pass-through");
    map_put(&g_pd_managed, pd, managed ? (void *)1 : (void *)2);
    return managed;
}

/* ------------------------------------------------------- feature spoofing */

static VkBool32 *feat_ptr(VkPhysicalDeviceFeatures *f, size_t i) {
    return (VkBool32 *)((char *)f + k_fakeable[i].off);
}

/* Features in the instance's spoof set that the driver reports as missing. */
static uint64_t missing_features(const InstanceData *id, const VkPhysicalDeviceFeatures *real) {
    uint64_t m = 0;
    for (size_t i = 0; i < N_FAKEABLE; i++)
        if ((id->fake_mask & (1ull << i)) && !*feat_ptr((VkPhysicalDeviceFeatures *)real, i)) m |= 1ull << i;
    return m;
}

static void set_features(VkPhysicalDeviceFeatures *f, uint64_t mask, VkBool32 v) {
    for (size_t i = 0; i < N_FAKEABLE; i++)
        if (mask & (1ull << i)) *feat_ptr(f, i) = v;
}

static void spoof(InstanceData *id, VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
    if (!id->fake || !pd_managed(id, pd)) return;
    uint64_t m = missing_features(id, f);
    if (!m) return;
    set_features(f, m, VK_TRUE);

    static uint64_t logged; /* say it once per process (goes to the Proton log) */
    if (!(m & ~logged)) return;
    logged |= m;
    char buf[1024];
    size_t n = 0;
    buf[0] = 0;
    for (size_t i = 0; i < N_FAKEABLE && n + 48 < sizeof buf; i++)
        if (m & (1ull << i)) n += (size_t)snprintf(buf + n, sizeof buf - n, " %s", k_fakeable[i].name);
    fprintf(stderr, "[bottle-present] reporting as supported (the GPU lacks them):%s\n", buf);
}

static PFN_vkGetPhysicalDeviceFeatures2 next_features2(InstanceData *id) {
    return id->GetPhysicalDeviceFeatures2 ? id->GetPhysicalDeviceFeatures2 : id->GetPhysicalDeviceFeatures2KHR;
}

/* Judged by the feature bit, not the extension list: the loader also lists extensions
 * that implicit layers declare in their manifest (ours declares transform feedback). */
static int pd_lacks_xfb(InstanceData *id, VkPhysicalDevice pd) {
    void *v = map_get(&g_pd_xfb, pd);
    if (v) return v == (void *)1;
    VkPhysicalDeviceTransformFeedbackFeaturesEXT x = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT};
    VkPhysicalDeviceFeatures2 f = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &x};
    PFN_vkGetPhysicalDeviceFeatures2 next = next_features2(id);
    if (next) next(pd, &f);
    int lacks = !x.transformFeedback;
    map_put(&g_pd_xfb, pd, lacks ? (void *)1 : (void *)2);
    return lacks;
}

static int fake_xfb_for(InstanceData *id, VkPhysicalDevice pd) {
    return id->fake && pd_managed(id, pd) && pd_lacks_xfb(id, pd);
}

static VKAPI_ATTR void VKAPI_CALL bp_GetPhysicalDeviceFeatures(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f) {
    InstanceData *id = instance_for(pd);
    id->GetPhysicalDeviceFeatures(pd, f);
    spoof(id, pd, f);
}

static void features2(InstanceData *id, VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f,
                      PFN_vkGetPhysicalDeviceFeatures2 next) {
    if (next) next(pd, f);
    else id->GetPhysicalDeviceFeatures(pd, &f->features);
    spoof(id, pd, &f->features);
    if (!fake_xfb_for(id, pd)) return;
    for (VkBaseOutStructure *s = f->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT) {
            VkPhysicalDeviceTransformFeedbackFeaturesEXT *x = (VkPhysicalDeviceTransformFeedbackFeaturesEXT *)s;
            x->transformFeedback = VK_TRUE;
            x->geometryStreams = VK_TRUE;
        }
}

/* vkd3d-proton (DirectX 12) on a managed device: single-texel buffer view offsets reported as
 * supported, and descriptor buffers hidden (see the top of the file). */
static int single_texel_for(InstanceData *id, VkPhysicalDevice pd) {
    return id->fake && id->vkd3d && pd_managed(id, pd);
}

static void texel_alignment(InstanceData *id, VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    if (!pd_managed(id, pd)) return;
    int spoof_it = single_texel_for(id, pd), changed = 0;
    for (VkBaseOutStructure *s = p->pNext; s; s = s->pNext) {
        VkBool32 *st = NULL, *un = NULL;
        VkDeviceSize *stb = NULL, *unb = NULL;
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES) {
            VkPhysicalDeviceVulkan13Properties *v = (VkPhysicalDeviceVulkan13Properties *)s;
            st = &v->storageTexelBufferOffsetSingleTexelAlignment; un = &v->uniformTexelBufferOffsetSingleTexelAlignment;
            stb = &v->storageTexelBufferOffsetAlignmentBytes; unb = &v->uniformTexelBufferOffsetAlignmentBytes;
        } else if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TEXEL_BUFFER_ALIGNMENT_PROPERTIES) {
            VkPhysicalDeviceTexelBufferAlignmentProperties *v = (VkPhysicalDeviceTexelBufferAlignmentProperties *)s;
            st = &v->storageTexelBufferOffsetSingleTexelAlignment; un = &v->uniformTexelBufferOffsetSingleTexelAlignment;
            stb = &v->storageTexelBufferOffsetAlignmentBytes; unb = &v->uniformTexelBufferOffsetAlignmentBytes;
        }
        if (!st) continue;
        if (g_test_texel_align) {  /* tests: what Venus on KosmicKrisp reports */
            *st = *un = VK_FALSE;
            *stb = *unb = g_test_texel_align;
        }
        if (spoof_it && (!*st || !*un)) { *st = *un = VK_TRUE; changed = 1; }
    }
    if (g_test_texel_align) p->properties.limits.minTexelBufferOffsetAlignment = g_test_texel_align;
    /* Native 16-bit shaders (D3D12 shader model 6.2, -enable-16bit-types): vkd3d-proton only
     * builds them on a device that keeps fp16 denormals and can set denormal handling per bit
     * width; KosmicKrisp reports neither (Metal has no such switch), so vkd3d-proton refused six
     * of The Witcher 3's compute shaders ("Attempting to use 16-bit operations in shader ...,
     * but this is not supported") and the work they do was missing: a dark rectangle that stays
     * put on screen (Oct 11, 00:40). Reported as supported to vkd3d: at worst the tiniest fp16
     * values (below 6e-5) come out as zero, which no picture shows. (BOTTLE_TEST_TEXEL_ALIGN
     * also makes a test device report what KosmicKrisp does here.) */
    int fp16 = 0;
    if (spoof_it || g_test_texel_align)
        for (VkBaseOutStructure *s = p->pNext; s; s = s->pNext) {
            VkBool32 *pre = NULL;
            VkShaderFloatControlsIndependence *ind = NULL;
            if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES) {
                VkPhysicalDeviceVulkan12Properties *v = (VkPhysicalDeviceVulkan12Properties *)s;
                pre = &v->shaderDenormPreserveFloat16; ind = &v->denormBehaviorIndependence;
            } else if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FLOAT_CONTROLS_PROPERTIES) {
                VkPhysicalDeviceFloatControlsProperties *v = (VkPhysicalDeviceFloatControlsProperties *)s;
                pre = &v->shaderDenormPreserveFloat16; ind = &v->denormBehaviorIndependence;
            }
            if (!pre) continue;
            if (g_test_texel_align) { *pre = VK_FALSE; *ind = VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_NONE; }
            if (!spoof_it) continue;
            if (!*pre) { *pre = VK_TRUE; fp16 = 1; }
            if (*ind == VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_NONE) { *ind = VK_SHADER_FLOAT_CONTROLS_INDEPENDENCE_32_BIT_ONLY; fp16 = 1; }
        }
    static int told_fp16;
    if (fp16 && !__atomic_exchange_n(&told_fp16, 1, __ATOMIC_RELAXED))
        fprintf(stderr, "[bottle-present] DirectX 12: reporting fp16 denormal handling as supported "
                        "(so vkd3d-proton builds native 16-bit shaders)\n");
    static int told;
    if (changed && !__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
        fprintf(stderr, "[bottle-present] DirectX 12: reporting single-texel buffer view offsets as supported "
                        "(vkd3d-proton keeps its typed views aligned without descriptor buffers)\n");
}

static void properties2(InstanceData *id, VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p,
                        PFN_vkGetPhysicalDeviceProperties2 next) {
    if (next) next(pd, p);
    else id->GetPhysicalDeviceProperties(pd, &p->properties);
    texel_alignment(id, pd, p);
    if (!fake_xfb_for(id, pd)) return;
    for (VkBaseOutStructure *s = p->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT) {
            VkPhysicalDeviceTransformFeedbackPropertiesEXT *x = (VkPhysicalDeviceTransformFeedbackPropertiesEXT *)s;
            x->maxTransformFeedbackStreams = 4;
            x->maxTransformFeedbackBuffers = 4;
            x->maxTransformFeedbackBufferSize = 0xffffffffu;
            x->maxTransformFeedbackStreamDataSize = 512;
            x->maxTransformFeedbackBufferDataSize = 512;
            x->maxTransformFeedbackBufferDataStride = 2048;
            x->transformFeedbackQueries = VK_TRUE;
            x->transformFeedbackStreamsLinesTriangles = VK_TRUE;
            x->transformFeedbackRasterizationStreamSelect = VK_FALSE;
            x->transformFeedbackDraw = VK_TRUE;
        }
}

static VKAPI_ATTR void VKAPI_CALL bp_GetPhysicalDeviceProperties2(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    InstanceData *id = instance_for(pd);
    properties2(id, pd, p, id->GetPhysicalDeviceProperties2 ? id->GetPhysicalDeviceProperties2 : id->GetPhysicalDeviceProperties2KHR);
}

static VKAPI_ATTR void VKAPI_CALL bp_GetPhysicalDeviceProperties2KHR(VkPhysicalDevice pd, VkPhysicalDeviceProperties2 *p) {
    InstanceData *id = instance_for(pd);
    properties2(id, pd, p, id->GetPhysicalDeviceProperties2KHR ? id->GetPhysicalDeviceProperties2KHR : id->GetPhysicalDeviceProperties2);
}

static VKAPI_ATTR void VKAPI_CALL bp_GetPhysicalDeviceFeatures2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    InstanceData *id = instance_for(pd);
    features2(id, pd, f, next_features2(id));
}

static VKAPI_ATTR void VKAPI_CALL bp_GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f) {
    InstanceData *id = instance_for(pd);
    features2(id, pd, f, id->GetPhysicalDeviceFeatures2KHR ? id->GetPhysicalDeviceFeatures2KHR : id->GetPhysicalDeviceFeatures2);
}

/* ------------------------------------------------------------------ device */

typedef struct {
    VkDevice device;
    VkPhysicalDevice pd;
    InstanceData *id;
    int managed;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkSetDeviceLoaderData set_loader_data;
    uint32_t qfam;
    VkQueue queue;
    VkCommandPool pool;
    pthread_mutex_t qlock;
    VkPhysicalDeviceMemoryProperties memprops;

    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkGetDeviceQueue GetDeviceQueue;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkQueueWaitIdle QueueWaitIdle;
    PFN_vkQueueBindSparse QueueBindSparse;
    PFN_vkDeviceWaitIdle DeviceWaitIdle;
    PFN_vkCreateImage CreateImage;
    PFN_vkDestroyImage DestroyImage;
    PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
    PFN_vkAllocateMemory AllocateMemory;
    PFN_vkFreeMemory FreeMemory;
    PFN_vkBindImageMemory BindImageMemory;
    PFN_vkCreateBuffer CreateBuffer;
    PFN_vkDestroyBuffer DestroyBuffer;
    PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
    PFN_vkBindBufferMemory BindBufferMemory;
    PFN_vkMapMemory MapMemory;
    PFN_vkUnmapMemory UnmapMemory;
    PFN_vkInvalidateMappedMemoryRanges InvalidateMappedMemoryRanges;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
    PFN_vkCreateFence CreateFence;
    PFN_vkDestroyFence DestroyFence;
    PFN_vkWaitForFences WaitForFences;
    PFN_vkResetFences ResetFences;

    int fake_xfb; /* app enabled our stand-in VK_EXT_transform_feedback */
    unsigned texel_check; /* bytes typed buffer views must be aligned to (vkd3d with the stand-in), or 0 */
    uint64_t max_texels;  /* maxTexelBufferElements: Metal's texture buffer width limit (2^28 here) */
    PFN_vkCreateBufferView CreateBufferView;
    PFN_vkCreateQueryPool CreateQueryPool;
    PFN_vkCmdBeginQuery CmdBeginQuery;
    PFN_vkCmdEndQuery CmdEndQuery;
    PFN_vkGetDeviceBufferMemoryRequirements GetDeviceBufferMemoryRequirements;

    /* BOTTLE_PRESENT_DEBUG counters: next-layer entry points of the wrapped calls */
    PFN_vkCmdDraw CmdDraw;
    PFN_vkCmdDrawIndexed CmdDrawIndexed;
    PFN_vkCmdDrawIndirect CmdDrawIndirect;
    PFN_vkCmdDrawIndexedIndirect CmdDrawIndexedIndirect;
    PFN_vkCmdDispatch CmdDispatch;
    PFN_vkCreateGraphicsPipelines CreateGraphicsPipelines;
    PFN_vkCreateComputePipelines CreateComputePipelines;
    PFN_vkQueueSubmit2 QueueSubmit2;
    PFN_vkQueueSubmit2KHR QueueSubmit2KHR;
    PFN_vkCmdBeginRendering CmdBeginRendering;
    PFN_vkCmdBeginRenderingKHR CmdBeginRenderingKHR;
    PFN_vkCmdBeginRenderPass CmdBeginRenderPass;
    PFN_vkCmdBeginRenderPass2 CmdBeginRenderPass2;
    PFN_vkCmdBeginRenderPass2KHR CmdBeginRenderPass2KHR;
    PFN_vkCmdPipelineBarrier2 CmdPipelineBarrier2;
    PFN_vkCmdPipelineBarrier2KHR CmdPipelineBarrier2KHR;
} DeviceData;

static Node *g_devices; /* VkDevice -> DeviceData* */

/* Run a queue call with the device's queue lock held (see bp_QueueSubmit). */
#define LOCKED(dd, call) ({ pthread_mutex_lock(&(dd)->qlock); VkResult r_ = (call); \
                            pthread_mutex_unlock(&(dd)->qlock); r_; })
static unsigned g_dev_gen; /* bumped when a device goes away: invalidates dd_fast's cache */

static DeviceData *device_for(const void *dispatchable) {
    /* Queues share their device's dispatch key. */
    DeviceData *found = NULL;
    void *key = dkey(dispatchable);
    pthread_mutex_lock(&g_lock);
    for (Node *n = g_devices; n; n = n->next) {
        DeviceData *dd = n->val;
        if ((void *)dd->device == dispatchable || dkey(dd->device) == key) { found = dd; break; }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

/* ---------------------------------------------------------------------- X11 */

static xcb_connection_t *g_conn;
static int g_have_shm;

static xcb_connection_t *xconn(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_conn) {
        /* Our own connection: window XIDs are global, and this keeps us off the
         * application's Xlib/XCB connection and its locking rules. */
        xcb_connection_t *c = xcb_connect(NULL, NULL);
        if (c && !xcb_connection_has_error(c)) {
            const xcb_query_extension_reply_t *ext = xcb_get_extension_data(c, &xcb_shm_id);
            g_have_shm = ext && ext->present;
            g_conn = c;
        } else if (c) {
            xcb_disconnect(c);
        }
    }
    xcb_connection_t *c = g_conn;
    pthread_mutex_unlock(&g_lock);
    return c;
}

static int window_info(uint32_t win, uint32_t *w, uint32_t *h, uint8_t *depth) {
    xcb_connection_t *c = xconn();
    if (!c) return 0;
    xcb_get_geometry_reply_t *r = xcb_get_geometry_reply(c, xcb_get_geometry(c, win), NULL);
    if (!r) return 0;
    if (w) *w = r->width;
    if (h) *h = r->height;
    if (depth) *depth = r->depth;
    free(r);
    return 1;
}

static uint32_t surface_window(VkSurfaceKHR s) {
    return (uint32_t)(uintptr_t)map_get(&g_surfaces, (void *)(uintptr_t)s);
}

/* ------------------------------------------------------- surface queries */

static const VkSurfaceFormatKHR k_formats[] = {
    {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
    {VK_FORMAT_B8G8R8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
    {VK_FORMAT_R8G8B8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
    {VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR},
};
static const VkPresentModeKHR k_modes[] = {VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR};

#define ARRAY_LEN(a) (uint32_t)(sizeof(a) / sizeof((a)[0]))

static void fill_caps(VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *c) {
    uint32_t w = 0, h = 0;
    if (!window_info(surface_window(surface), &w, &h, NULL) || !w || !h) w = h = 1;
    memset(c, 0, sizeof *c);
    c->minImageCount = 2;
    c->maxImageCount = MAX_IMAGES;
    c->currentExtent = (VkExtent2D){w, h};
    c->minImageExtent = (VkExtent2D){w, h};
    c->maxImageExtent = (VkExtent2D){w, h};
    c->maxImageArrayLayers = 1;
    c->supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    c->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    c->supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR | VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    c->supportedUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                             VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
}

static VkResult fill_array(uint32_t *count, void *out, const void *src, uint32_t n, size_t elem) {
    if (!out) { *count = n; return VK_SUCCESS; }
    uint32_t k = *count < n ? *count : n;
    memcpy(out, src, k * elem);
    *count = k;
    return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfaceSupportKHR(
    VkPhysicalDevice pd, uint32_t qfi, VkSurfaceKHR surface, VkBool32 *supported) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfaceSupportKHR(pd, qfi, surface, supported);
    *supported = VK_TRUE;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfaceCapabilitiesKHR(
    VkPhysicalDevice pd, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *caps) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, caps);
    fill_caps(surface, caps);
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfaceFormatsKHR(
    VkPhysicalDevice pd, VkSurfaceKHR surface, uint32_t *count, VkSurfaceFormatKHR *formats) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfaceFormatsKHR(pd, surface, count, formats);
    return fill_array(count, formats, k_formats, ARRAY_LEN(k_formats), sizeof k_formats[0]);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfacePresentModesKHR(
    VkPhysicalDevice pd, VkSurfaceKHR surface, uint32_t *count, VkPresentModeKHR *modes) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfacePresentModesKHR(pd, surface, count, modes);
    return fill_array(count, modes, k_modes, ARRAY_LEN(k_modes), sizeof k_modes[0]);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfaceCapabilities2KHR(
    VkPhysicalDevice pd, const VkPhysicalDeviceSurfaceInfo2KHR *info, VkSurfaceCapabilities2KHR *caps) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfaceCapabilities2KHR(pd, info, caps);
    fill_caps(info->surface, &caps->surfaceCapabilities);

    VkPresentModeKHR asked = VK_PRESENT_MODE_FIFO_KHR;
    for (const VkBaseInStructure *s = info->pNext; s; s = s->pNext)
        if (s->sType == VK_STRUCTURE_TYPE_SURFACE_PRESENT_MODE_EXT)
            asked = ((const VkSurfacePresentModeEXT *)s)->presentMode;

    for (VkBaseOutStructure *s = caps->pNext; s; s = s->pNext) {
        switch (s->sType) {
        case VK_STRUCTURE_TYPE_SURFACE_PROTECTED_CAPABILITIES_KHR:
            ((VkSurfaceProtectedCapabilitiesKHR *)s)->supportsProtected = VK_FALSE;
            break;
        case VK_STRUCTURE_TYPE_SHARED_PRESENT_SURFACE_CAPABILITIES_KHR:
            ((VkSharedPresentSurfaceCapabilitiesKHR *)s)->sharedPresentSupportedUsageFlags = 0;
            break;
        case VK_STRUCTURE_TYPE_SURFACE_PRESENT_MODE_COMPATIBILITY_EXT: {
            VkSurfacePresentModeCompatibilityEXT *c = (VkSurfacePresentModeCompatibilityEXT *)s;
            if (c->pPresentModes && c->presentModeCount >= 1) c->pPresentModes[0] = asked;
            c->presentModeCount = 1;
            break;
        }
        case VK_STRUCTURE_TYPE_SURFACE_PRESENT_SCALING_CAPABILITIES_EXT: {
            VkSurfacePresentScalingCapabilitiesEXT *c = (VkSurfacePresentScalingCapabilitiesEXT *)s;
            c->supportedPresentScaling = 0;
            c->supportedPresentGravityX = 0;
            c->supportedPresentGravityY = 0;
            c->minScaledImageExtent = caps->surfaceCapabilities.minImageExtent;
            c->maxScaledImageExtent = caps->surfaceCapabilities.maxImageExtent;
            break;
        }
        default:
            break;
        }
    }
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDeviceSurfaceFormats2KHR(
    VkPhysicalDevice pd, const VkPhysicalDeviceSurfaceInfo2KHR *info, uint32_t *count, VkSurfaceFormat2KHR *formats) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceSurfaceFormats2KHR(pd, info, count, formats);
    uint32_t n = ARRAY_LEN(k_formats);
    if (!formats) { *count = n; return VK_SUCCESS; }
    uint32_t k = *count < n ? *count : n;
    for (uint32_t i = 0; i < k; i++) formats[i].surfaceFormat = k_formats[i];
    *count = k;
    return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetPhysicalDevicePresentRectanglesKHR(
    VkPhysicalDevice pd, VkSurfaceKHR surface, uint32_t *count, VkRect2D *rects) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDevicePresentRectanglesKHR(pd, surface, count, rects);
    VkSurfaceCapabilitiesKHR c;
    fill_caps(surface, &c);
    VkRect2D r = {{0, 0}, c.currentExtent};
    return fill_array(count, rects, &r, 1, sizeof r);
}

static VKAPI_ATTR VkBool32 VKAPI_CALL bp_GetPhysicalDeviceXcbPresentationSupportKHR(
    VkPhysicalDevice pd, uint32_t qfi, xcb_connection_t *c, xcb_visualid_t v) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceXcbPresentationSupportKHR(pd, qfi, c, v);
    return VK_TRUE;
}

static VKAPI_ATTR VkBool32 VKAPI_CALL bp_GetPhysicalDeviceXlibPresentationSupportKHR(
    VkPhysicalDevice pd, uint32_t qfi, Display *dpy, VisualID v) {
    InstanceData *id = instance_for(pd);
    if (!pd_managed(id, pd)) return id->GetPhysicalDeviceXlibPresentationSupportKHR(pd, qfi, dpy, v);
    return VK_TRUE;
}

/* ---------------------------------------------------------------- surfaces */

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateXcbSurfaceKHR(
    VkInstance inst, const VkXcbSurfaceCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSurfaceKHR *s) {
    InstanceData *id = instance_for(inst);
    if (!id->CreateXcbSurfaceKHR) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkResult r = id->CreateXcbSurfaceKHR(inst, ci, a, s);
    if (r == VK_SUCCESS) map_put(&g_surfaces, (void *)(uintptr_t)*s, (void *)(uintptr_t)ci->window);
    return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateXlibSurfaceKHR(
    VkInstance inst, const VkXlibSurfaceCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSurfaceKHR *s) {
    InstanceData *id = instance_for(inst);
    if (!id->CreateXlibSurfaceKHR) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkResult r = id->CreateXlibSurfaceKHR(inst, ci, a, s);
    if (r == VK_SUCCESS) map_put(&g_surfaces, (void *)(uintptr_t)*s, (void *)(uintptr_t)ci->window);
    return r;
}

static VKAPI_ATTR void VKAPI_CALL bp_DestroySurfaceKHR(VkInstance inst, VkSurfaceKHR s, const VkAllocationCallbacks *a) {
    InstanceData *id = instance_for(inst);
    map_del(&g_surfaces, (void *)(uintptr_t)s);
    if (id->DestroySurfaceKHR) id->DestroySurfaceKHR(inst, s, a);
}

/* --------------------------------------------------------------- swapchain */

/*
 * Presentation runs on a thread per swapchain, so the app never waits for the GPU or
 * for the X server (Xvnc is single-threaded and encodes VNC frames between requests):
 *
 *   vkQueuePresentKHR  submits the image -> host buffer copy (after the app's semaphores)
 *                      with that image's fence, queues the image for the presenter, returns.
 *   presenter thread   waits for the copy's fence, copies the pixels into a free MIT-SHM
 *                      segment (two per swapchain) and sends XShmPutImage without waiting;
 *                      the server's ShmCompletion event frees the segment again. With vsync
 *                      off (IMMEDIATE/MAILBOX) a frame is skipped when a newer one is queued;
 *                      with vsync (FIFO) every frame is shown and the game is paced by it.
 *
 * The presenter has its own X connection; the window size is checked every 30 frames.
 * BOTTLE_PRESENT_SYNC=1 does all of it inside vkQueuePresentKHR (the old behaviour).
 */

#define NSEG 2

typedef struct {
    xcb_shm_seg_t seg;
    void *addr;
    int busy;
    double put_ms; /* when it was last sent (test builds use it to fake a slow server) */
} ShmSeg;

typedef struct {
    DeviceData *dd;
    uint32_t window;
    VkExtent2D extent;
    VkFormat format;
    int swizzle; /* RGBA formats -> X wants BGRX */
    uint32_t count, next;
    VkImage images[MAX_IMAGES];
    VkDeviceMemory imem[MAX_IMAGES];
    VkBuffer bufs[MAX_IMAGES];
    VkDeviceMemory bmem[MAX_IMAGES];
    void *bmap[MAX_IMAGES];
    VkCommandBuffer cmds[MAX_IMAGES];
    VkFence fences[MAX_IMAGES];
    int coherent;

    /* X side: used only by the presenter (or by vkQueuePresentKHR in sync mode) */
    xcb_connection_t *xc;
    xcb_gcontext_t gc;
    uint8_t depth;
    int shm_event; /* MIT-SHM first_event, -1 without MIT-SHM */
    ShmSeg shm[NSEG];

    /* hand-off between vkQueuePresentKHR and the presenter */
    pthread_mutex_t m;
    pthread_cond_t cv;
    pthread_t thread;
    int threaded, fifo;
    volatile int quit, resized;
    int busy_img[MAX_IMAGES]; /* copy submitted, presenter not done with it yet */
    uint32_t queue[MAX_IMAGES], qhead, qlen;

    /* the FPS counter: the game's presents per second, updated twice a second */
    double fpsc_t0;
    uint32_t fpsc_n;
    volatile int fpsc_val;

    /* pacing (always; the game's thread, in vkQueuePresentKHR) */
    double pace_t0, pace_last, pace_max;
    int told_first;          /* "first frame on screen" said (bottle-whyquit looks for it) */
    uint32_t pace_frames, pace_over50, pace_over100;

    /* stats (BOTTLE_PRESENT_DEBUG) */
    uint64_t jobs, dropped;
    double last_frame_ms; /* when the game last presented (presenter thread) */
    int stalled;          /* said that frames stopped coming */
    struct timespec t0;
    double ms_wait, ms_blit, ms_block;
} Swapchain;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int find_memtype(DeviceData *dd, uint32_t bits, VkMemoryPropertyFlags want, VkMemoryPropertyFlags avoid) {
    for (uint32_t i = 0; i < dd->memprops.memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = dd->memprops.memoryTypes[i].propertyFlags;
        if ((bits & (1u << i)) && (f & want) == want && !(f & avoid)) return (int)i;
    }
    return -1;
}

/* ---- X side ---- */

static void x_setup(Swapchain *sc, VkDeviceSize bytes) {
    sc->shm_event = -1;
    sc->depth = 24;
    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (!c || xcb_connection_has_error(c)) {
        if (c) xcb_disconnect(c);
        LOG("presenter: can't connect to the X server");
        return;
    }
    sc->xc = c;
    xcb_get_geometry_reply_t *g = xcb_get_geometry_reply(c, xcb_get_geometry(c, sc->window), NULL);
    if (g) { sc->depth = g->depth; free(g); }
    sc->gc = xcb_generate_id(c);
    xcb_create_gc(c, sc->gc, sc->window, 0, NULL);

    const xcb_query_extension_reply_t *ext = xcb_get_extension_data(c, &xcb_shm_id);
    if (ext && ext->present) {
        int ok = 1;
        for (int k = 0; k < NSEG && ok; k++) {
            int id = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
            void *a = NULL;
            if (id >= 0) {
                a = shmat(id, NULL, 0);
                if (a == (void *)-1) a = NULL;
                if (a) {
                    xcb_shm_seg_t seg = xcb_generate_id(c);
                    xcb_generic_error_t *e = xcb_request_check(c, xcb_shm_attach_checked(c, seg, (uint32_t)id, 0));
                    if (e) { free(e); shmdt(a); a = NULL; }
                    else { sc->shm[k].seg = seg; sc->shm[k].addr = a; }
                }
                shmctl(id, IPC_RMID, NULL); /* freed once both sides detach */
            }
            if (!a) ok = 0;
        }
        if (ok) sc->shm_event = ext->first_event;
    }
    xcb_flush(c);
}

static void x_teardown(Swapchain *sc) {
    if (sc->xc) {
        for (int k = 0; k < NSEG; k++)
            if (sc->shm[k].seg) xcb_shm_detach(sc->xc, sc->shm[k].seg);
        if (sc->gc) xcb_free_gc(sc->xc, sc->gc);
        xcb_flush(sc->xc);
        xcb_disconnect(sc->xc);
        sc->xc = NULL;
    }
    for (int k = 0; k < NSEG; k++)
        if (sc->shm[k].addr) { shmdt(sc->shm[k].addr); sc->shm[k].addr = NULL; }
}

/* Drain pending X events: ShmCompletion frees its segment; an X error (window gone)
 * frees them all, since no completion will follow. */
static void x_events(Swapchain *sc) {
    xcb_generic_event_t *ev;
    while ((ev = xcb_poll_for_event(sc->xc))) {
        uint8_t type = ev->response_type & 0x7f;
        if (sc->shm_event >= 0 && type == (uint8_t)(sc->shm_event + XCB_SHM_COMPLETION)) {
            xcb_shm_completion_event_t *ce = (xcb_shm_completion_event_t *)ev;
            for (int k = 0; k < NSEG; k++)
                if (sc->shm[k].seg == ce->shmseg) sc->shm[k].busy = 0;
        } else if (type == 0) {
            for (int k = 0; k < NSEG; k++) sc->shm[k].busy = 0;
        }
        free(ev);
    }
}

static int newer_frame_waiting(Swapchain *sc) {
    return sc->threaded && !sc->fifo && __atomic_load_n(&sc->qlen, __ATOMIC_RELAXED) > 0;
}

/* A free SHM segment, or -1: waits for the server to release one, but gives up as soon
 * as a newer frame is queued (the current one is then skipped). */
static int x_free_seg(Swapchain *sc) {
    for (;;) {
        x_events(sc);
        for (int k = 0; k < NSEG; k++) {
#ifdef BOTTLE_TEST_SLOW_MS /* test builds only: the server takes this long per frame */
            if (now_ms() - sc->shm[k].put_ms < BOTTLE_TEST_SLOW_MS) continue;
#endif
            if (!sc->shm[k].busy) return k;
        }
        if (newer_frame_waiting(sc) || sc->quit || xcb_connection_has_error(sc->xc)) return -1;
        struct pollfd p = {.fd = xcb_get_file_descriptor(sc->xc), .events = POLLIN};
        poll(&p, 1, 2);
    }
}

/* ---- the FPS counter ----
 * Steam draws its "In-game FPS counter" with its in-game overlay, which this ARM64 Steam
 * doesn't put into x86 games (Oct 9: no gameoverlayrenderer in their processes). The layer
 * shows every frame anyway (it copies it into the X window), so it draws the counter itself,
 * from Steam's own setting: InGameOverlayShowFPSCorner in the newest
 * userdata/<id>/config/localconfig.vdf (0 off, 1 top left, 2 top right, 3 bottom right,
 * 4 bottom left; ...FPSContrast 1 = white on black). Re-read every 2 s, so changing it in
 * Steam while playing takes effect. Not for Steam's own interface (zink). */
static pthread_mutex_t g_fpsc_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_fpsc_corner = -1, g_fpsc_contrast, g_fpsc_forced = -1;
static double g_fpsc_next;
static time_t g_fpsc_mtime;
static char g_fpsc_path[2400];

static void fpsc_find_config(void) {
    const char *home = getenv("HOME");
    char bases[3][512];
    int nb = 0;
    const char *ci = getenv("STEAM_COMPAT_CLIENT_INSTALL_PATH");
    if (ci && *ci) snprintf(bases[nb++], sizeof bases[0], "%s", ci);
    if (home) {
        snprintf(bases[nb++], sizeof bases[0], "%s/.local/share/Steam", home);
        snprintf(bases[nb++], sizeof bases[0], "%s/.steam/steam", home);
    }
    time_t best = 0;
    for (int b = 0; b < nb; b++) {
        char dir[1600];
        snprintf(dir, sizeof dir, "%s/userdata", bases[b]);
        DIR *d = opendir(dir);
        if (!d) continue;
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
            char f[2400];
            struct stat st;
            snprintf(f, sizeof f, "%s/%s/config/localconfig.vdf", dir, e->d_name);
            if (stat(f, &st) == 0 && st.st_mtime > best) {
                best = st.st_mtime;
                snprintf(g_fpsc_path, sizeof g_fpsc_path, "%s", f);
            }
        }
        closedir(d);
        if (best) return;
    }
}
/* the value of "key" "value" in a VDF text, or -1 */
static int vdf_int(const char *text, const char *key) {
    char k[96];
    snprintf(k, sizeof k, "\"%s\"", key);
    const char *p = strstr(text, k);
    if (!p) return -1;
    p += strlen(k);
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return -1;
    return atoi(p + 1);
}
static struct { int state; } g_ov_fwd;  /* (g_ov is defined further down; its state mirrors here) */
static int fpsc_corner(void) {
    /* (stays on while Steam's overlay is hosted, until that overlay is known to draw) */
    if (g_zink) return 0;
    double t = now_ms();
    pthread_mutex_lock(&g_fpsc_lock);
    if (g_fpsc_forced < 0) {
        const char *e = getenv("BOTTLE_FPS_COUNTER");
        g_fpsc_forced = (e && *e >= '0' && *e <= '4') ? *e - '0' : 9;
    }
    if (g_fpsc_forced != 9) { pthread_mutex_unlock(&g_fpsc_lock); return g_fpsc_forced; }
    /* Steam's own overlay works in games now (Oct 10: hosted by this layer, its renderer
     * preloaded by Proton's user_settings.py), with its FPS counter and performance monitor:
     * this stand-in only on request (BOTTLE_FPS_COUNTER=1-4), so the two never show at once. */
    if (1) { pthread_mutex_unlock(&g_fpsc_lock); return 0; }
    if (t >= g_fpsc_next) {
        g_fpsc_next = t + 2000;
        if (!g_fpsc_path[0]) fpsc_find_config();
        struct stat st;
        if (g_fpsc_path[0] && stat(g_fpsc_path, &st) == 0 && st.st_mtime != g_fpsc_mtime) {
            g_fpsc_mtime = st.st_mtime;
            FILE *f = fopen(g_fpsc_path, "rb");
            if (f && st.st_size > 0 && st.st_size < (64 << 20)) {
                char *buf = malloc((size_t)st.st_size + 1);
                size_t n = buf ? fread(buf, 1, (size_t)st.st_size, f) : 0;
                if (buf) {
                    buf[n] = 0;
                    int c = vdf_int(buf, "InGameOverlayShowFPSCorner");
                    int was = g_fpsc_corner;
                    g_fpsc_corner = c < 0 ? 0 : c;
                    g_fpsc_contrast = vdf_int(buf, "InGameOverlayShowFPSContrast") == 1;
                    if (was != g_fpsc_corner)
                        LOGA("FPS counter: %s (Steam's setting, %s)", g_fpsc_corner ? "on" : "off", g_fpsc_path);
                    free(buf);
                }
            }
            if (f) fclose(f);
        }
        if (g_fpsc_corner < 0) g_fpsc_corner = 0;
    }
    int c = g_fpsc_corner;
    pthread_mutex_unlock(&g_fpsc_lock);
    return c;
}
/* counts the game's presents (its thread, in vkQueuePresentKHR) */
static void fpsc_frame(Swapchain *sc) {
    double t = now_ms();
    if (sc->fpsc_t0 == 0 || t - sc->fpsc_t0 > 5000) { sc->fpsc_t0 = t; sc->fpsc_n = 0; return; }
    sc->fpsc_n++;
    if (t - sc->fpsc_t0 >= 500) {
        sc->fpsc_val = (int)(sc->fpsc_n * 1000.0 / (t - sc->fpsc_t0) + 0.5);
        sc->fpsc_t0 = t;
        sc->fpsc_n = 0;
    }
}
static const uint8_t k_digits[10][7] = { /* 5x7, top row first, bit 4 = left column */
    {0x0e,0x11,0x13,0x15,0x19,0x11,0x0e}, {0x04,0x0c,0x04,0x04,0x04,0x04,0x0e},
    {0x0e,0x11,0x01,0x02,0x04,0x08,0x1f}, {0x1f,0x02,0x04,0x02,0x01,0x11,0x0e},
    {0x02,0x06,0x0a,0x12,0x1f,0x02,0x02}, {0x1f,0x10,0x1e,0x01,0x01,0x11,0x0e},
    {0x06,0x08,0x10,0x1e,0x11,0x11,0x0e}, {0x1f,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0e,0x11,0x11,0x0e,0x11,0x11,0x0e}, {0x0e,0x11,0x11,0x0f,0x01,0x02,0x0c},
};
/* draws the counter into a BGRX frame (w x h, tightly packed) */
static void fpsc_draw(uint32_t *d, uint32_t w, uint32_t h, int corner, int fps) {
    if (corner < 1 || corner > 4 || w < 64 || h < 64) return;
    char txt[8];
    int n = snprintf(txt, sizeof txt, "%d", fps < 0 ? 0 : fps > 9999 ? 9999 : fps);
    int sc = (int)(h / 360); if (sc < 2) sc = 2;
    int gw = 5 * sc, gh = 7 * sc, gap = sc, pad = 2 * sc, margin = 2 * sc;
    int bw = n * gw + (n - 1) * gap + 2 * pad, bh = gh + 2 * pad;
    int x0 = (corner == 1 || corner == 4) ? margin : (int)w - margin - bw;
    int y0 = (corner == 1 || corner == 2) ? margin : (int)h - margin - bh;
    if (x0 < 0 || y0 < 0 || x0 + bw > (int)w || y0 + bh > (int)h) return;
    uint32_t fg = g_fpsc_contrast ? 0x00ffffffu : 0x00b8f05au; /* bright green, or white */
    for (int y = 0; y < bh; y++) {                               /* the box: darkened, or black */
        uint32_t *row = d + (size_t)(y0 + y) * w + x0;
        for (int x = 0; x < bw; x++)
            row[x] = g_fpsc_contrast ? 0 : (row[x] >> 2) & 0x003f3f3fu;
    }
    for (int i = 0; i < n; i++) {
        const uint8_t *g = k_digits[txt[i] - '0'];
        int gx = x0 + pad + i * (gw + gap), gy = y0 + pad;
        for (int r = 0; r < 7; r++)
            for (int c = 0; c < 5; c++) {
                if (!(g[r] & (0x10 >> c))) continue;
                for (int yy = 0; yy < sc; yy++) {
                    uint32_t *px = d + (size_t)(gy + r * sc + yy) * w + gx + c * sc;
                    for (int xx = 0; xx < sc; xx++) px[xx] = fg;
                }
            }
    }
}

static void x_put(Swapchain *sc, const uint8_t *src, int seg) {
    xcb_connection_t *c = sc->xc;
    uint32_t w = sc->extent.width, h = sc->extent.height;
    size_t px = (size_t)w * h;

    if (seg >= 0) {
        uint32_t *d = sc->shm[seg].addr;
        if (sc->swizzle) {
            const uint32_t *s = (const uint32_t *)src;
            for (size_t i = 0; i < px; i++) {
                uint32_t p = s[i]; /* little endian RGBA -> BGRA */
                d[i] = (p & 0xff00ff00u) | ((p & 0xffu) << 16) | ((p >> 16) & 0xffu);
            }
        } else {
            memcpy(d, src, px * 4);
        }
        int corner = fpsc_corner();
        if (corner) fpsc_draw(d, w, h, corner, sc->fpsc_val);
        xcb_shm_put_image(c, sc->window, sc->gc, (uint16_t)w, (uint16_t)h, 0, 0, (uint16_t)w, (uint16_t)h,
                          0, 0, sc->depth, XCB_IMAGE_FORMAT_Z_PIXMAP, 1 /* send ShmCompletion */,
                          sc->shm[seg].seg, 0);
        sc->shm[seg].busy = 1;
        sc->shm[seg].put_ms = now_ms();
        xcb_flush(c);
        return;
    }

    /* No MIT-SHM: PutImage in strips that fit the request limit (the server copies them). */
    uint32_t maxreq = xcb_get_maximum_request_length(c) * 4;
    uint32_t stride = w * 4;
    uint32_t rows = (maxreq - 64) / stride;
    if (rows == 0) rows = 1;
    uint8_t *tmp = sc->swizzle ? malloc((size_t)rows * stride) : NULL;
    for (uint32_t y = 0; y < h; y += rows) {
        uint32_t n = (h - y < rows) ? h - y : rows;
        const uint8_t *p = src + (size_t)y * stride;
        if (tmp) {
            const uint32_t *s = (const uint32_t *)p;
            uint32_t *d = (uint32_t *)tmp;
            for (size_t i = 0; i < (size_t)w * n; i++) {
                uint32_t v = s[i];
                d[i] = (v & 0xff00ff00u) | ((v & 0xffu) << 16) | ((v >> 16) & 0xffu);
            }
            p = tmp;
        }
        xcb_put_image(c, XCB_IMAGE_FORMAT_Z_PIXMAP, sc->window, sc->gc, (uint16_t)w, (uint16_t)n, 0, (int16_t)y,
                      0, sc->depth, n * stride, p);
    }
    free(tmp);
    xcb_flush(c);
}

/* ---- delivering one frame ---- */

static void take_counts(char *buf, size_t len, unsigned frames);

/* Wait for image img's copy, then show it, unless a newer frame is already waiting. */
static void deliver(Swapchain *sc, uint32_t img, int newer_waiting) {
    DeviceData *dd = sc->dd;
    double t0 = now_ms();
    VkResult r = dd->WaitForFences(dd->device, 1, &sc->fences[img], VK_TRUE, UINT64_MAX);
    double t1 = now_ms();
    int shown = 0;
    if (r == VK_SUCCESS && sc->xc && !newer_waiting) {
        int seg = sc->shm_event >= 0 ? x_free_seg(sc) : -1;
        if (sc->shm_event < 0 || seg >= 0) {
            if (!sc->coherent) {
                VkMappedMemoryRange mr = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                                          .memory = sc->bmem[img], .offset = 0, .size = VK_WHOLE_SIZE};
                dd->InvalidateMappedMemoryRanges(dd->device, 1, &mr);
            }
            x_put(sc, sc->bmap[img], seg);
            shown = 1;
        }
    } else if (r != VK_SUCCESS) {
        LOG("waiting for the present copy failed: %d", r);
    }
    double t2 = now_ms();

    sc->ms_wait += t1 - t0;
    sc->ms_blit += t2 - t1;
    if (!shown) sc->dropped++;
    sc->jobs++;

    if (g_debug > 0 && sc->jobs % 120 == 0) {
        struct timespec t;
        clock_gettime(CLOCK_MONOTONIC, &t);
        double dt = (t.tv_sec - sc->t0.tv_sec) + (t.tv_nsec - sc->t0.tv_nsec) / 1e9;
        pthread_mutex_lock(&sc->m);
        double blocked = sc->ms_block;
        sc->ms_block = 0;
        pthread_mutex_unlock(&sc->m);
        /* fps = frames the game presented; shown = frames that reached the screen.
         * gpu: presenter waiting for the GPU to finish a frame (+ our copy); screen: copying
         * it to X; blocked: the game waiting for us (should stay near 0). */
        char counts[320];
        take_counts(counts, sizeof counts, 120);
        LOG("%.1f fps (last 120 frames, %ux%u) | shown %.1f fps | per frame: gpu %.1f ms, screen %.1f ms, "
            "game blocked %.1f ms%s%s",
            120.0 / dt, sc->extent.width, sc->extent.height, (120.0 - sc->dropped) / dt,
            sc->ms_wait / 120, sc->ms_blit / 120, blocked / 120, sc->threaded ? "" : " (sync)", counts);
        sc->t0 = t;
        sc->ms_wait = sc->ms_blit = 0;
        sc->dropped = 0;
    }
}

/* Window resized? Then the app should recreate the swapchain (VK_SUBOPTIMAL_KHR).
 * A round trip to the X server, so it runs every 30 frames and never while an image is held. */
static void check_resize(Swapchain *sc) {
    if (sc->jobs % 30 != 0 || !sc->xc) return;
    xcb_get_geometry_reply_t *g = xcb_get_geometry_reply(sc->xc, xcb_get_geometry(sc->xc, sc->window), NULL);
    if (g) {
        sc->resized = g->width != sc->extent.width || g->height != sc->extent.height;
        free(g);
    }
}

/* The game stopped presenting (a freeze, a loading screen without frames, or minimized):
 * say so in the log once, with the time, and again when frames come back. */
#define STALL_MS 3000

static void *presenter(void *arg) {
    Swapchain *sc = arg;
    sc->last_frame_ms = now_ms();
    pthread_mutex_lock(&sc->m);
    for (;;) {
        while (!sc->quit && sc->qlen == 0) {
            struct timespec until;
            clock_gettime(CLOCK_MONOTONIC, &until);
            until.tv_sec += 1;
            pthread_cond_timedwait(&sc->cv, &sc->m, &until);
            if (!sc->stalled && sc->jobs > 0 && now_ms() - sc->last_frame_ms > STALL_MS) {
                sc->stalled = 1;
                LOG("no new frame from the game for %d s (it stopped presenting after %llu frames)",
                    STALL_MS / 1000, (unsigned long long)sc->jobs);
            }
        }
        if (sc->qlen == 0) break; /* quit, and everything queued is done */
        if (sc->stalled) {
            LOG("frames again, after %.1f s without any", (now_ms() - sc->last_frame_ms) / 1000);
            sc->stalled = 0;
        }
        sc->last_frame_ms = now_ms();
        uint32_t img = sc->queue[sc->qhead];
        sc->qhead = (sc->qhead + 1) % MAX_IMAGES;
        sc->qlen--;
        int newer = !sc->fifo && sc->qlen > 0;
        pthread_mutex_unlock(&sc->m);
        deliver(sc, img, newer);
        pthread_mutex_lock(&sc->m);
        sc->busy_img[img] = 0;
        pthread_cond_broadcast(&sc->cv);
        pthread_mutex_unlock(&sc->m);
        check_resize(sc);
        pthread_mutex_lock(&sc->m);
    }
    pthread_mutex_unlock(&sc->m);
    return NULL;
}

/* ---- swapchain objects ---- */

static void destroy_swapchain(Swapchain *sc) {
    DeviceData *dd = sc->dd;
    VkDevice dev = dd->device;
    if (sc->threaded) {
        pthread_mutex_lock(&sc->m);
        sc->quit = 1;
        pthread_cond_broadcast(&sc->cv);
        pthread_mutex_unlock(&sc->m);
        pthread_join(sc->thread, NULL);
    }
    pthread_mutex_lock(&dd->qlock);
    if (dd->queue) dd->QueueWaitIdle(dd->queue);
    pthread_mutex_unlock(&dd->qlock);
    x_teardown(sc);
    for (uint32_t i = 0; i < sc->count; i++) {
        if (sc->bmap[i]) dd->UnmapMemory(dev, sc->bmem[i]);
        if (sc->bufs[i]) dd->DestroyBuffer(dev, sc->bufs[i], NULL);
        if (sc->bmem[i]) dd->FreeMemory(dev, sc->bmem[i], NULL);
        if (sc->images[i]) dd->DestroyImage(dev, sc->images[i], NULL);
        if (sc->imem[i]) dd->FreeMemory(dev, sc->imem[i], NULL);
        if (sc->fences[i]) dd->DestroyFence(dev, sc->fences[i], NULL);
    }
    /* command buffers go away with the pool */
    pthread_cond_destroy(&sc->cv);
    pthread_mutex_destroy(&sc->m);
    free(sc);
}

static void record_copy(DeviceData *dd, Swapchain *sc, uint32_t i) {
    VkCommandBuffer cb = sc->cmds[i];
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    dd->BeginCommandBuffer(cb, &bi);

    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier to_src = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = sc->images[i],
        .subresourceRange = range,
    };
    dd->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                           0, NULL, 0, NULL, 1, &to_src);

    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {sc->extent.width, sc->extent.height, 1},
    };
    dd->CmdCopyImageToBuffer(cb, sc->images[i], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, sc->bufs[i], 1, &region);

    VkImageMemoryBarrier back = to_src;
    back.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    back.dstAccessMask = 0;
    back.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    back.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkBufferMemoryBarrier to_host = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = sc->bufs[i],
        .offset = 0,
        .size = VK_WHOLE_SIZE,
    };
    dd->CmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                           VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
                           0, NULL, 1, &to_host, 1, &back);
    dd->EndCommandBuffer(cb);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateSwapchainKHR(
    VkDevice dev, const VkSwapchainCreateInfoKHR *ci, const VkAllocationCallbacks *a, VkSwapchainKHR *out) {
    (void)a;
    DeviceData *dd = device_for(dev);
    uint32_t win = surface_window(ci->surface);
    if (!win) { LOG("unknown surface"); return VK_ERROR_SURFACE_LOST_KHR; }

    Swapchain *sc = calloc(1, sizeof *sc);
    pthread_mutex_init(&sc->m, NULL);
    pthread_condattr_t ca; /* the presenter's timed waits use the monotonic clock */
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&sc->cv, &ca);
    pthread_condattr_destroy(&ca);
    sc->dd = dd;
    sc->window = win;
    sc->extent = ci->imageExtent;
    sc->format = ci->imageFormat;
    /* Bytes in memory R,G,B,A (these four formats) -> X wants B,G,R,X. */
    sc->swizzle = ci->imageFormat == VK_FORMAT_R8G8B8A8_UNORM || ci->imageFormat == VK_FORMAT_R8G8B8A8_SRGB ||
                  ci->imageFormat == VK_FORMAT_A8B8G8R8_UNORM_PACK32 || ci->imageFormat == VK_FORMAT_A8B8G8R8_SRGB_PACK32;
    if (g_swap_rb) sc->swizzle = !sc->swizzle;
    sc->count = ci->minImageCount < 2 ? 2 : (ci->minImageCount > MAX_IMAGES ? MAX_IMAGES : ci->minImageCount);
    sc->fifo = ci->presentMode == VK_PRESENT_MODE_FIFO_KHR || ci->presentMode == VK_PRESENT_MODE_FIFO_RELAXED_KHR;
    VkDeviceSize bytes = (VkDeviceSize)sc->extent.width * sc->extent.height * 4;
    VkResult r = VK_SUCCESS;

    for (uint32_t i = 0; i < sc->count && r == VK_SUCCESS; i++) {
        VkImageCreateInfo ici = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .flags = (ci->flags & VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR) ? VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT : 0,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = ci->imageFormat,
            .extent = {ci->imageExtent.width, ci->imageExtent.height, 1},
            .mipLevels = 1,
            .arrayLayers = ci->imageArrayLayers ? ci->imageArrayLayers : 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = ci->imageUsage | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = ci->imageSharingMode,
            .queueFamilyIndexCount = ci->imageSharingMode == VK_SHARING_MODE_CONCURRENT ? ci->queueFamilyIndexCount : 0,
            .pQueueFamilyIndices = ci->imageSharingMode == VK_SHARING_MODE_CONCURRENT ? ci->pQueueFamilyIndices : NULL,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        /* pass VkImageFormatListCreateInfo through for mutable-format swapchains */
        for (const VkBaseInStructure *s = ci->pNext; s; s = s->pNext)
            if (s->sType == VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO) {
                static __thread VkImageFormatListCreateInfo fl;
                fl = *(const VkImageFormatListCreateInfo *)s;
                fl.pNext = NULL;
                ici.pNext = &fl;
            }
        if ((r = dd->CreateImage(dev, &ici, NULL, &sc->images[i]))) break;
        VkMemoryRequirements mr;
        dd->GetImageMemoryRequirements(dev, sc->images[i], &mr);
        int mt = find_memtype(dd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, 0);
        if (mt < 0) mt = find_memtype(dd, mr.memoryTypeBits, 0, 0);
        VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                   .allocationSize = mr.size, .memoryTypeIndex = (uint32_t)mt};
        if ((r = dd->AllocateMemory(dev, &ai, NULL, &sc->imem[i]))) break;
        if ((r = dd->BindImageMemory(dev, sc->images[i], sc->imem[i], 0))) break;

        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes,
                                  .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                  .sharingMode = VK_SHARING_MODE_EXCLUSIVE};
        if ((r = dd->CreateBuffer(dev, &bci, NULL, &sc->bufs[i]))) break;
        dd->GetBufferMemoryRequirements(dev, sc->bufs[i], &mr);
        /* Readback: prefer cached host memory; coherent only as a fallback. */
        mt = find_memtype(dd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_CACHED_BIT, 0);
        if (mt < 0) mt = find_memtype(dd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
        if (mt < 0) { r = VK_ERROR_OUT_OF_DEVICE_MEMORY; LOG("no host-visible memory type"); break; }
        sc->coherent = !!(dd->memprops.memoryTypes[mt].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        ai.allocationSize = mr.size;
        ai.memoryTypeIndex = (uint32_t)mt;
        if ((r = dd->AllocateMemory(dev, &ai, NULL, &sc->bmem[i]))) break;
        if ((r = dd->BindBufferMemory(dev, sc->bufs[i], sc->bmem[i], 0))) break;
        if ((r = dd->MapMemory(dev, sc->bmem[i], 0, VK_WHOLE_SIZE, 0, &sc->bmap[i]))) break;

        VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                           .commandPool = dd->pool,
                                           .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                           .commandBufferCount = 1};
        if ((r = dd->AllocateCommandBuffers(dev, &cai, &sc->cmds[i]))) break;
        if (dd->set_loader_data) dd->set_loader_data(dev, sc->cmds[i]);
        record_copy(dd, sc, i);

        VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        if ((r = dd->CreateFence(dev, &fci, NULL, &sc->fences[i]))) break;
    }
    if (r != VK_SUCCESS) {
        LOG("swapchain creation failed: %d", r);
        destroy_swapchain(sc);
        return r;
    }

    x_setup(sc, bytes);
    __atomic_store_n(&g_ov_fw, sc->extent.width, __ATOMIC_RELAXED);   /* for the overlay trace */
    __atomic_store_n(&g_ov_fh, sc->extent.height, __ATOMIC_RELAXED);
    clock_gettime(CLOCK_MONOTONIC, &sc->t0);
    const char *sync = getenv("BOTTLE_PRESENT_SYNC");
    if (!(sync && *sync && *sync != '0') && sc->xc) {
        sc->threaded = pthread_create(&sc->thread, NULL, presenter, sc) == 0;
    }
    LOG("swapchain %ux%u fmt=%d%s images=%u window=0x%x shm=%s coherent=%d presenter=%s vsync=%s",
        sc->extent.width, sc->extent.height, sc->format, sc->swizzle ? " (swapping R/B)" : "", sc->count, win,
        sc->shm_event >= 0 ? "yes" : "no", sc->coherent, sc->threaded ? "thread" : "sync", sc->fifo ? "on" : "off");
    *out = (VkSwapchainKHR)(uintptr_t)sc;
    return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL bp_DestroySwapchainKHR(VkDevice dev, VkSwapchainKHR s, const VkAllocationCallbacks *a) {
    (void)dev; (void)a;
    if (!s) return;
    destroy_swapchain((Swapchain *)(uintptr_t)s);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetSwapchainImagesKHR(VkDevice dev, VkSwapchainKHR s, uint32_t *count, VkImage *images) {
    (void)dev;
    Swapchain *sc = (Swapchain *)(uintptr_t)s;
    return fill_array(count, images, sc->images, sc->count, sizeof(VkImage));
}

static VkResult acquire(DeviceData *dd, Swapchain *sc, VkSemaphore sem, VkFence fence, uint32_t *idx) {
    *idx = sc->next;
    sc->next = (sc->next + 1) % sc->count;
    if (sem != VK_NULL_HANDLE || fence != VK_NULL_HANDLE) {
        /* Signals after everything already on the queue, including our earlier copy of
         * this image, so the app can't draw into it while we still read it. */
        VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                           .signalSemaphoreCount = sem != VK_NULL_HANDLE ? 1 : 0,
                           .pSignalSemaphores = &sem};
        pthread_mutex_lock(&dd->qlock);
        VkResult r = dd->QueueSubmit(dd->queue, 1, &si, fence);
        pthread_mutex_unlock(&dd->qlock);
        if (r != VK_SUCCESS) return r;
    }
    return sc->resized ? VK_SUBOPTIMAL_KHR : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_AcquireNextImageKHR(
    VkDevice dev, VkSwapchainKHR s, uint64_t timeout, VkSemaphore sem, VkFence fence, uint32_t *idx) {
    (void)dev; (void)timeout;
    Swapchain *sc = (Swapchain *)(uintptr_t)s;
    return acquire(sc->dd, sc, sem, fence, idx);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_AcquireNextImage2KHR(VkDevice dev, const VkAcquireNextImageInfoKHR *info, uint32_t *idx) {
    (void)dev;
    Swapchain *sc = (Swapchain *)(uintptr_t)info->swapchain;
    return acquire(sc->dd, sc, info->semaphore, info->fence, idx);
}

/* Frame pacing, always on (one line every 10 s of play, into the game's log): how even the
 * game's frames are, and how much shader compiling went on. "over 50 ms" frames are the
 * hitches a player sees; the pipelines say whether new shaders caused them. Freezes of a few
 * seconds count as slow frames too; only a gap of over a minute (the game in the background,
 * a long loading screen) starts a new period. */
#define PACE_PERIOD_MS 10000.0
/* pipelines the game had compiled (counted in bp_Create*Pipelines), the time that took (summed
 * over its threads) and the longest single call */
static uint64_t g_pace_pipes;
static double g_pace_pipe_ms, g_pace_pipe_max;
static pthread_mutex_t g_pace_lock = PTHREAD_MUTEX_INITIALIZER; /* the two doubles */
static void pace_frame(Swapchain *sc) {
    /* once per swapchain: a game that closes later did show something (bottle-whyquit) */
    if (!sc->told_first && !g_zink) {
        sc->told_first = 1;
        LOGA("first frame on screen (%ux%u)", sc->extent.width, sc->extent.height);
    }
    if (g_no_pace) return;
    double t = now_ms();
    if (sc->pace_last == 0 || t - sc->pace_last > 60000) {
        sc->pace_t0 = sc->pace_last = t;
        sc->pace_frames = sc->pace_over50 = sc->pace_over100 = 0;
        sc->pace_max = 0;
        return;
    }
    double dt = t - sc->pace_last;
    sc->pace_last = t;
    sc->pace_frames++;
    if (dt > sc->pace_max) sc->pace_max = dt;
    if (dt > 50) sc->pace_over50++;
    if (dt > 100) sc->pace_over100++;
    if (t - sc->pace_t0 < PACE_PERIOD_MS) return;
    uint64_t pipes = __atomic_exchange_n(&g_pace_pipes, 0, __ATOMIC_RELAXED);
    pthread_mutex_lock(&g_pace_lock);
    double pms = g_pace_pipe_ms, pmax = g_pace_pipe_max;
    g_pace_pipe_ms = g_pace_pipe_max = 0;
    pthread_mutex_unlock(&g_pace_lock);
    double secs = (t - sc->pace_t0) / 1000;
    LOGA("pacing: %.1f fps over %.0f s (%ux%u), slowest frame %.0f ms, %u frames over 50 ms, %u over 100 ms"
         " | new pipelines: %llu, %.0f ms compiling them (longest %.0f ms)",
         sc->pace_frames / secs, secs, sc->extent.width, sc->extent.height, sc->pace_max, sc->pace_over50,
         sc->pace_over100, (unsigned long long)pipes, pms, pmax);
    sc->pace_t0 = t;
    sc->pace_frames = sc->pace_over50 = sc->pace_over100 = 0;
    sc->pace_max = 0;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pi) {
    VkResult final = VK_SUCCESS;
    for (uint32_t i = 0; i < pi->swapchainCount; i++) {
        Swapchain *sc = (Swapchain *)(uintptr_t)pi->pSwapchains[i];
        DeviceData *dd = sc->dd;
        uint32_t img = pi->pImageIndices[i];
        VkResult r;

        pace_frame(sc);
        if (!g_zink) fpsc_frame(sc);

        /* The presenter must be done with this image's buffer and fence from last time. */
        double tb = now_ms();
        pthread_mutex_lock(&sc->m);
        while (sc->busy_img[img]) pthread_cond_wait(&sc->cv, &sc->m);
        sc->ms_block += now_ms() - tb;
        pthread_mutex_unlock(&sc->m);

        uint32_t nwait = (i == 0) ? pi->waitSemaphoreCount : 0;
        VkPipelineStageFlags stages[16];
        if (nwait > 16) nwait = 16;
        for (uint32_t k = 0; k < nwait; k++) stages[k] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        if (i == 0 && pi->waitSemaphoreCount == 0) {
            /* No semaphores: make sure the app's work on its queue is done. */
            (void)LOCKED(dd, dd->QueueWaitIdle(queue));
        }
        dd->ResetFences(dd->device, 1, &sc->fences[img]);
        VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                           .waitSemaphoreCount = nwait,
                           .pWaitSemaphores = pi->pWaitSemaphores,
                           .pWaitDstStageMask = stages,
                           .commandBufferCount = 1,
                           .pCommandBuffers = &sc->cmds[img]};
        pthread_mutex_lock(&dd->qlock);
        r = dd->QueueSubmit(dd->queue, 1, &si, sc->fences[img]);
        pthread_mutex_unlock(&dd->qlock);

        if (r != VK_SUCCESS) {
            LOG("present submit failed: %d", r);
        } else if (sc->threaded) {
            pthread_mutex_lock(&sc->m);
            sc->busy_img[img] = 1;
            sc->queue[(sc->qhead + sc->qlen) % MAX_IMAGES] = img;
            sc->qlen++;
            pthread_cond_broadcast(&sc->cv);
            pthread_mutex_unlock(&sc->m);
        } else {
            deliver(sc, img, 0);
            check_resize(sc);
        }
        if (r == VK_SUCCESS && sc->resized) r = VK_SUBOPTIMAL_KHR;
        if (pi->pResults) pi->pResults[i] = r;
        if (r != VK_SUCCESS && final == VK_SUCCESS) final = r;
    }
    return final;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetDeviceGroupPresentCapabilitiesKHR(
    VkDevice dev, VkDeviceGroupPresentCapabilitiesKHR *caps) {
    (void)dev;
    memset(caps->presentMask, 0, sizeof caps->presentMask);
    caps->presentMask[0] = 1;
    caps->modes = VK_DEVICE_GROUP_PRESENT_MODE_LOCAL_BIT_KHR;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_GetDeviceGroupSurfacePresentModesKHR(
    VkDevice dev, VkSurfaceKHR s, VkDeviceGroupPresentModeFlagsKHR *modes) {
    (void)dev; (void)s;
    *modes = VK_DEVICE_GROUP_PRESENT_MODE_LOCAL_BIT_KHR;
    return VK_SUCCESS;
}

/* -------------------------------------- stand-in VK_EXT_transform_feedback */

/* Stream output is a no-op: draws still rasterize, nothing is captured. */
static VKAPI_ATTR void VKAPI_CALL bp_CmdBindTransformFeedbackBuffersEXT(
    VkCommandBuffer cb, uint32_t first, uint32_t count, const VkBuffer *b, const VkDeviceSize *o, const VkDeviceSize *s) {
    (void)cb; (void)first; (void)count; (void)b; (void)o; (void)s;
}

static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginTransformFeedbackEXT(
    VkCommandBuffer cb, uint32_t first, uint32_t count, const VkBuffer *b, const VkDeviceSize *o) {
    (void)cb; (void)first; (void)count; (void)b; (void)o;
}

static VKAPI_ATTR void VKAPI_CALL bp_CmdEndTransformFeedbackEXT(
    VkCommandBuffer cb, uint32_t first, uint32_t count, const VkBuffer *b, const VkDeviceSize *o) {
    (void)cb; (void)first; (void)count; (void)b; (void)o;
}

static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginQueryIndexedEXT(
    VkCommandBuffer cb, VkQueryPool pool, uint32_t query, VkQueryControlFlags flags, uint32_t index) {
    (void)index;
    DeviceData *dd = device_for(cb);
    if (dd && dd->CmdBeginQuery) dd->CmdBeginQuery(cb, pool, query, flags);
}

static VKAPI_ATTR void VKAPI_CALL bp_CmdEndQueryIndexedEXT(VkCommandBuffer cb, VkQueryPool pool, uint32_t query, uint32_t index) {
    (void)index;
    DeviceData *dd = device_for(cb);
    if (dd && dd->CmdEndQuery) dd->CmdEndQuery(cb, pool, query);
}

static VKAPI_ATTR void VKAPI_CALL bp_CmdDrawIndirectByteCountEXT(
    VkCommandBuffer cb, uint32_t instances, uint32_t first, VkBuffer counter, VkDeviceSize offset,
    uint32_t counterOffset, uint32_t stride) {
    (void)cb; (void)instances; (void)first; (void)counter; (void)offset; (void)counterOffset; (void)stride;
}

/* Stream-output statistics queries (D3D SO_STATISTICS): an occlusion query pool stands in, so
 * begin/end/reset/copy stay valid; the numbers mean nothing (no game here relies on them). */
static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateQueryPool(
    VkDevice dev, const VkQueryPoolCreateInfo *ci, const VkAllocationCallbacks *a, VkQueryPool *qp) {
    DeviceData *dd = device_for(dev);
    if (ci->queryType != VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT) return dd->CreateQueryPool(dev, ci, a, qp);
    VkQueryPoolCreateInfo c = *ci;
    c.queryType = VK_QUERY_TYPE_OCCLUSION;
    c.pipelineStatistics = 0;
    return dd->CreateQueryPool(dev, &c, a, qp);
}

#define XFB_BUFFER_BITS (VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT | VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_COUNTER_BUFFER_BIT_EXT)

static void strip_xfb_usage(VkBufferCreateInfo *c) {
    c->usage &= ~(VkBufferUsageFlags)XFB_BUFFER_BITS;
    if (!c->usage) c->usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT; /* usage must not be 0 */
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateBuffer(
    VkDevice dev, const VkBufferCreateInfo *ci, const VkAllocationCallbacks *a, VkBuffer *b) {
    DeviceData *dd = device_for(dev);
    if (!(ci->usage & XFB_BUFFER_BITS)) return dd->CreateBuffer(dev, ci, a, b);
    VkBufferCreateInfo c = *ci;
    strip_xfb_usage(&c);
    return dd->CreateBuffer(dev, &c, a, b);
}

static VKAPI_ATTR void VKAPI_CALL bp_GetDeviceBufferMemoryRequirements(
    VkDevice dev, const VkDeviceBufferMemoryRequirements *info, VkMemoryRequirements2 *req) {
    DeviceData *dd = device_for(dev);
    if (!dd->GetDeviceBufferMemoryRequirements) return;
    if (!(info->pCreateInfo->usage & XFB_BUFFER_BITS)) {
        dd->GetDeviceBufferMemoryRequirements(dev, info, req);
        return;
    }
    VkBufferCreateInfo c = *info->pCreateInfo;
    strip_xfb_usage(&c);
    VkDeviceBufferMemoryRequirements i2 = *info;
    i2.pCreateInfo = &c;
    dd->GetDeviceBufferMemoryRequirements(dev, &i2, req);
}

/* ------------------------------------- typed buffer views (DirectX 12) */

/* With the single-texel stand-in, a view whose offset the Mac's GPU can't take as is: Metal
 * makes texture buffers at 16-byte offsets. Logged (the first few) so a game that draws
 * wrong because of it can be told apart; the view is still created. */
/* Bytes per texel of the formats texel buffers use; 0 for the rest. */
static unsigned texel_bytes(VkFormat f) {
    if (f >= 9 && f <= 15) return 1;                 /* R8 */
    if ((f >= 16 && f <= 22) || (f >= 70 && f <= 76)) return 2;   /* R8G8, R16 */
    if (f >= 23 && f <= 36) return 3;                /* R8G8B8, B8G8R8 */
    if ((f >= 37 && f <= 69) || (f >= 77 && f <= 83) || (f >= 98 && f <= 100) || f == 122 || f == 123)
        return 4;                                    /* RGBA8 and friends, 10:10:10:2, R16G16, R32, 11:11:10, 9:9:9:5 */
    if (f >= 84 && f <= 90) return 6;                /* R16G16B16 */
    if ((f >= 91 && f <= 97) || (f >= 101 && f <= 103) || (f >= 110 && f <= 112)) return 8;
    if (f >= 104 && f <= 106) return 12;             /* R32G32B32 */
    if ((f >= 107 && f <= 109) || (f >= 113 && f <= 115)) return 16;
    return 0;
}

/* A typed view wider than maxTexelBufferElements is invalid Vulkan that most drivers let pass,
 * but KosmicKrisp hands it to Metal as a texture buffer that wide, and Metal's always-on check
 * stops the whole process: the VM went down with "MTLTextureDescriptor has width (536870912)
 * greater than the maximum allowed size of 268435456" (Oct 10, 22:17, vkd3d-proton's
 * test_large_texel_buffer_view; vkd3d-proton passes D3D12 views that big on). Such a view is
 * cut to the limit: what lies beyond reads as out of bounds, instead of the VM stopping. */
static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateBufferView(
    VkDevice dev, const VkBufferViewCreateInfo *ci, const VkAllocationCallbacks *a, VkBufferView *v) {
    DeviceData *dd = device_for(dev);
    unsigned tb = dd->max_texels ? texel_bytes(ci->format) : 0;
    if (tb) {
        VkDeviceSize range = ci->range;
        if (range == VK_WHOLE_SIZE && dd->GetBufferMemoryRequirements) {
            VkMemoryRequirements mr = {0};
            dd->GetBufferMemoryRequirements(dev, ci->buffer, &mr);
            /* (the buffer's own size is at most this; less its alignment, to stay inside it) */
            range = mr.size > ci->offset + mr.alignment ? mr.size - ci->offset - mr.alignment : 0;
        }
        if (range / tb > dd->max_texels) {
            VkBufferViewCreateInfo c = *ci;
            c.range = (VkDeviceSize)dd->max_texels * tb;
            static unsigned n;
            unsigned k = __atomic_add_fetch(&n, 1, __ATOMIC_RELAXED);
            if (k <= 10 || (k & (k - 1)) == 0)
                fprintf(stderr, "[bottle-present] typed buffer view of %llu texels cut to the GPU's limit of %llu "
                                "(format %d; Metal would stop the VM) (%u so far)\n",
                        (unsigned long long)(range / tb), (unsigned long long)dd->max_texels, (int)ci->format, k);
            return bp_CreateBufferView(dev, &c, a, v);
        }
    }
    if (dd->texel_check && ci->offset % dd->texel_check) {
        static unsigned n;
        unsigned k = __atomic_add_fetch(&n, 1, __ATOMIC_RELAXED);
        if (k <= 10 || (k & (k - 1)) == 0)
            fprintf(stderr, "[bottle-present] DirectX 12: typed buffer view at offset %llu (format %d, %llu bytes), "
                            "not a multiple of %u: the Mac's GPU may read it from the wrong place (%u so far)\n",
                    (unsigned long long)ci->offset, (int)ci->format, (unsigned long long)ci->range, dd->texel_check, k);
    }
    return dd->CreateBufferView(dev, ci, a, v);
}

/* ------------------------------------------------- debug counters */

/* With BOTTLE_PRESENT_DEBUG=1 the layer counts what the game asks of the GPU, and the
 * presenter prints it with the frame-time split. Tells "too many draws" (per-call cost of
 * the VM -> Mac translation) apart from "new pipelines" (shader compiling on the Mac). */
static uint64_t g_st_indexed, g_st_indirect;
static uint64_t g_st_draws, g_st_dispatches, g_st_submits, g_st_pipes, g_st_passes, g_st_barriers, g_st_queries;
static double g_st_pipe_ms;
static pthread_mutex_t g_st_lock = PTHREAD_MUTEX_INITIALIZER; /* g_st_pipe_ms only */

/* device_for() without the lock and list walk on every draw. */
static DeviceData *dd_fast(const void *dispatchable) {
    static __thread DeviceData *c_dd;
    static __thread void *c_key;
    static __thread unsigned c_gen;
    void *key = dkey(dispatchable);
    unsigned gen = __atomic_load_n(&g_dev_gen, __ATOMIC_ACQUIRE);
    if (!c_dd || key != c_key || gen != c_gen) {
        c_dd = device_for(dispatchable);
        c_key = key;
        c_gen = gen;
    }
    return c_dd;
}

#define COUNT(var, n) __atomic_fetch_add(&(var), (uint64_t)(n), __ATOMIC_RELAXED)

static VKAPI_ATTR void VKAPI_CALL bp_CmdDraw(VkCommandBuffer cb, uint32_t vc, uint32_t ic, uint32_t fv, uint32_t fi) {
    COUNT(g_st_draws, 1);
    dd_fast(cb)->CmdDraw(cb, vc, ic, fv, fi);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdDrawIndexed(VkCommandBuffer cb, uint32_t xc, uint32_t ic, uint32_t fx,
                                                    int32_t vo, uint32_t fi) {
    COUNT(g_st_draws, 1);
    COUNT(g_st_indexed, 1);
    dd_fast(cb)->CmdDrawIndexed(cb, xc, ic, fx, vo, fi);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdDrawIndirect(VkCommandBuffer cb, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t st) {
    COUNT(g_st_draws, 1);
    COUNT(g_st_indirect, 1);
    dd_fast(cb)->CmdDrawIndirect(cb, b, o, n, st);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdDrawIndexedIndirect(VkCommandBuffer cb, VkBuffer b, VkDeviceSize o, uint32_t n, uint32_t st) {
    COUNT(g_st_draws, 1);
    COUNT(g_st_indexed, 1);
    COUNT(g_st_indirect, 1);
    dd_fast(cb)->CmdDrawIndexedIndirect(cb, b, o, n, st);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdDispatch(VkCommandBuffer cb, uint32_t x, uint32_t y, uint32_t z) {
    COUNT(g_st_dispatches, 1);
    dd_fast(cb)->CmdDispatch(cb, x, y, z);
}
/* Render passes and barriers: on the Mac each can mean a new Metal encoder and a GPU drain. */
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginRendering(VkCommandBuffer cb, const VkRenderingInfo *ri) {
    COUNT(g_st_passes, 1);
    dd_fast(cb)->CmdBeginRendering(cb, ri);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginRenderingKHR(VkCommandBuffer cb, const VkRenderingInfo *ri) {
    COUNT(g_st_passes, 1);
    dd_fast(cb)->CmdBeginRenderingKHR(cb, ri);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginRenderPass(VkCommandBuffer cb, const VkRenderPassBeginInfo *bi, VkSubpassContents c) {
    COUNT(g_st_passes, 1);
    dd_fast(cb)->CmdBeginRenderPass(cb, bi, c);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginRenderPass2(VkCommandBuffer cb, const VkRenderPassBeginInfo *bi, const VkSubpassBeginInfo *si) {
    COUNT(g_st_passes, 1);
    dd_fast(cb)->CmdBeginRenderPass2(cb, bi, si);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginRenderPass2KHR(VkCommandBuffer cb, const VkRenderPassBeginInfo *bi, const VkSubpassBeginInfo *si) {
    COUNT(g_st_passes, 1);
    dd_fast(cb)->CmdBeginRenderPass2KHR(cb, bi, si);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdPipelineBarrier(
    VkCommandBuffer cb, VkPipelineStageFlags src, VkPipelineStageFlags dst, VkDependencyFlags dep,
    uint32_t nm, const VkMemoryBarrier *m, uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *i) {
    COUNT(g_st_barriers, 1);
    dd_fast(cb)->CmdPipelineBarrier(cb, src, dst, dep, nm, m, nb, b, ni, i);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdPipelineBarrier2(VkCommandBuffer cb, const VkDependencyInfo *di) {
    COUNT(g_st_barriers, 1);
    dd_fast(cb)->CmdPipelineBarrier2(cb, di);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdPipelineBarrier2KHR(VkCommandBuffer cb, const VkDependencyInfo *di) {
    COUNT(g_st_barriers, 1);
    dd_fast(cb)->CmdPipelineBarrier2KHR(cb, di);
}
static VKAPI_ATTR void VKAPI_CALL bp_CmdBeginQuery(VkCommandBuffer cb, VkQueryPool pool, uint32_t q, VkQueryControlFlags f) {
    COUNT(g_st_queries, 1);
    dd_fast(cb)->CmdBeginQuery(cb, pool, q, f);
}
static void count_pipes(uint32_t n, double ms) {
    COUNT(g_st_pipes, n);
    COUNT(g_pace_pipes, n);
    pthread_mutex_lock(&g_st_lock);
    g_st_pipe_ms += ms;
    pthread_mutex_unlock(&g_st_lock);
    pthread_mutex_lock(&g_pace_lock);
    g_pace_pipe_ms += ms;
    if (ms > g_pace_pipe_max) g_pace_pipe_max = ms;
    pthread_mutex_unlock(&g_pace_lock);
}
/* Pipelines are created with an answer, never "fire and forget" (games only; BOTTLE_SYNC_PIPELINES=0
 * turns it off). Venus creates a pipeline asynchronously when the calling thread is one that
 * records or submits (DXVK's CS thread: every compute pipeline, and graphics ones it can't
 * hand to a worker): the call returns success at once and the Mac builds it later, in line on
 * the main command ring. If the Mac then fails to build it, the pipeline simply doesn't exist
 * there, the next command buffer that uses it is a fatal error for the whole GPU context
 * (virtio-gpu SUBMIT_3D answered 0x1200), the game gets "device lost", and DXVK's exception
 * kills it under Wine ("Exception frame is not in stack limits"): CS2 every time it builds its
 * menu's shaders, Witcher 3 when macOS's Metal compiler service went away (Oct 9). Asking for
 * VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT makes Venus wait for the Mac's answer
 * (VN_PIPELINE_CREATE_SYNC_MASK in vn_pipeline.c): a failure comes back as an error, which
 * DXVK logs and survives (it skips what that pipeline would have drawn). The wait itself costs
 * nothing extra: the async build held up the main ring for as long. Not done when the app
 * passes VkPipelineCreateFlags2CreateInfo (its flags replace these; not used by DXVK here). */
static int pipes_force_sync(const void *pnext) {
    if (g_async_pipes || g_zink) return 0;
    for (const VkBaseInStructure *b = pnext; b; b = b->pNext)
        if (b->sType == VK_STRUCTURE_TYPE_PIPELINE_CREATE_FLAGS_2_CREATE_INFO_KHR) return 0;
    return 1;
}
static void pipes_failed(const char *kind, uint32_t n, VkResult r) {
    static unsigned told;
    if (r == VK_SUCCESS || r == VK_PIPELINE_COMPILE_REQUIRED) return;
    if (__atomic_add_fetch(&told, 1, __ATOMIC_RELAXED) <= 20)
        LOGA("the Mac couldn't build a %s pipeline (result %d, %u in the call); the game goes on without it", kind, (int)r, n);
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateGraphicsPipelines(
    VkDevice dev, VkPipelineCache c, uint32_t n, const VkGraphicsPipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *p) {
    double t = now_ms();
    VkGraphicsPipelineCreateInfo local[8], *mod = NULL;
    int sync = 0;
    for (uint32_t i = 0; i < n; i++) if (pipes_force_sync(ci[i].pNext)) { sync = 1; break; }
    if (sync) {
        mod = n <= 8 ? local : malloc(n * sizeof *mod);
        if (mod) {
            memcpy(mod, ci, n * sizeof *mod);
            for (uint32_t i = 0; i < n; i++)
                if (pipes_force_sync(mod[i].pNext)) mod[i].flags |= VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT;
        }
    }
    VkResult r = dd_fast(dev)->CreateGraphicsPipelines(dev, c, n, mod ? mod : ci, a, p);
    if (mod && mod != local) free(mod);
    count_pipes(n, now_ms() - t);
    pipes_failed("graphics", n, r);
    /* A geometry shader here means an app (or zink, internally) uses a feature this GPU lacks
     * and the layer may have reported as present: say so once, with the result. */
    static int told_gs;
    for (uint32_t i = 0; i < n && !told_gs; i++)
        for (uint32_t k = 0; !(ci[i].flags & VK_PIPELINE_CREATE_LIBRARY_BIT_KHR) && k < ci[i].stageCount && !told_gs; k++)
            if (ci[i].pStages[k].stage == VK_SHADER_STAGE_GEOMETRY_BIT) {
                told_gs = 1;
                LOGA("a pipeline with a geometry shader was created (result %d); this GPU has none, so what it draws may be missing", (int)r);
            }
    return r;
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateComputePipelines(
    VkDevice dev, VkPipelineCache c, uint32_t n, const VkComputePipelineCreateInfo *ci, const VkAllocationCallbacks *a, VkPipeline *p) {
    double t = now_ms();
    VkComputePipelineCreateInfo local[8], *mod = NULL;
    int sync = 0;
    for (uint32_t i = 0; i < n; i++) if (pipes_force_sync(ci[i].pNext)) { sync = 1; break; }
    if (sync) {
        mod = n <= 8 ? local : malloc(n * sizeof *mod);
        if (mod) {
            memcpy(mod, ci, n * sizeof *mod);
            for (uint32_t i = 0; i < n; i++)
                if (pipes_force_sync(mod[i].pNext)) mod[i].flags |= VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT;
        }
    }
    VkResult r = dd_fast(dev)->CreateComputePipelines(dev, c, n, mod ? mod : ci, a, p);
    if (mod && mod != local) free(mod);
    count_pipes(n, now_ms() - t);
    pipes_failed("compute", n, r);
    return r;
}
/* Queue access. Vulkan wants one thread at a time on a queue, and the app guarantees that
 * for its own calls, but this layer also submits from vkAcquireNextImageKHR (to signal the
 * app's semaphore/fence) and when a swapchain goes away: calls the app may make from another
 * thread while it submits (DXVK acquires on its CS thread and submits on dxvk-submit). So
 * every queue operation on a managed device goes through dd->qlock (LOCKED). Without it two
 * threads could be inside Venus' queue code at once; DMC5 aborted silently, about a second
 * after its swapchain was recreated, on some launches. */
static VKAPI_ATTR VkResult VKAPI_CALL bp_QueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f) {
    if (g_debug > 0) COUNT(g_st_submits, 1);
    DeviceData *dd = dd_fast(q);
    return LOCKED(dd, dd->QueueSubmit(q, n, s, f));
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_QueueSubmit2(VkQueue q, uint32_t n, const VkSubmitInfo2 *s, VkFence f) {
    if (g_debug > 0) COUNT(g_st_submits, 1);
    DeviceData *dd = dd_fast(q);
    return LOCKED(dd, dd->QueueSubmit2(q, n, s, f));
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_QueueSubmit2KHR(VkQueue q, uint32_t n, const VkSubmitInfo2 *s, VkFence f) {
    if (g_debug > 0) COUNT(g_st_submits, 1);
    DeviceData *dd = dd_fast(q);
    return LOCKED(dd, dd->QueueSubmit2KHR(q, n, s, f));
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_QueueWaitIdle(VkQueue q) {
    DeviceData *dd = dd_fast(q);
    return LOCKED(dd, dd->QueueWaitIdle(q));
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_QueueBindSparse(VkQueue q, uint32_t n, const VkBindSparseInfo *b, VkFence f) {
    DeviceData *dd = dd_fast(q);
    return LOCKED(dd, dd->QueueBindSparse(q, n, b, f));
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_DeviceWaitIdle(VkDevice dev) {  /* touches every queue */
    DeviceData *dd = dd_fast(dev);
    return LOCKED(dd, dd->DeviceWaitIdle(dev));
}
#undef COUNT

/* "| draws 2400, ..." for the frame-time line; resets the counters. */
static void take_counts(char *buf, size_t len, unsigned frames) {
    uint64_t draws = __atomic_exchange_n(&g_st_draws, 0, __ATOMIC_RELAXED);
    uint64_t indexed = __atomic_exchange_n(&g_st_indexed, 0, __ATOMIC_RELAXED);
    uint64_t indirect = __atomic_exchange_n(&g_st_indirect, 0, __ATOMIC_RELAXED);
    uint64_t disp = __atomic_exchange_n(&g_st_dispatches, 0, __ATOMIC_RELAXED);
    uint64_t subs = __atomic_exchange_n(&g_st_submits, 0, __ATOMIC_RELAXED);
    uint64_t pipes = __atomic_exchange_n(&g_st_pipes, 0, __ATOMIC_RELAXED);
    uint64_t passes = __atomic_exchange_n(&g_st_passes, 0, __ATOMIC_RELAXED);
    uint64_t barriers = __atomic_exchange_n(&g_st_barriers, 0, __ATOMIC_RELAXED);
    uint64_t queries = __atomic_exchange_n(&g_st_queries, 0, __ATOMIC_RELAXED);
    pthread_mutex_lock(&g_st_lock);
    double pms = g_st_pipe_ms;
    g_st_pipe_ms = 0;
    pthread_mutex_unlock(&g_st_lock);
    double f = frames;
    snprintf(buf, len, " | game asks per frame: %.0f draws (%.0f indexed, %.0f indirect), %.0f compute, %.0f render passes, %.0f barriers, %.0f queries, "
             "%.1f submits | new pipelines: %llu in %u frames (%.0f ms in the game)",
             draws / f, indexed / f, indirect / f, disp / f, passes / f, barriers / f, queries / f, subs / f, (unsigned long long)pipes, frames, pms);
}

/* ------------------------------------------------- extension enumeration */

static const char *k_strip[] = {
    VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    "VK_KHR_swapchain_mutable_format",
    "VK_EXT_swapchain_maintenance1",
    "VK_KHR_present_id",
    "VK_KHR_present_wait",
    "VK_KHR_present_id2",          /* vkd3d-proton 3.x uses these when listed; Venus lists them */
    "VK_KHR_present_wait2",
    "VK_EXT_present_timing",
    "VK_KHR_present_mode_fifo_latest_ready",
    "VK_EXT_present_mode_fifo_latest_ready",
    "VK_KHR_swapchain_maintenance1",
    "VK_KHR_incremental_present",
    "VK_GOOGLE_display_timing",
    "VK_EXT_full_screen_exclusive",
    "VK_KHR_display_swapchain",
    "VK_EXT_hdr_metadata",
};

static int stripped(const char *name) {
    for (uint32_t i = 0; i < ARRAY_LEN(k_strip); i++)
        if (!strcmp(name, k_strip[i])) return 1;
    return 0;
}

static const VkExtensionProperties k_swapchain_ext = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, 70};

static VKAPI_ATTR VkResult VKAPI_CALL bp_EnumerateDeviceExtensionProperties(
    VkPhysicalDevice pd, const char *layer, uint32_t *count, VkExtensionProperties *props) {
    if (layer && !strcmp(layer, LAYER_NAME))
        return fill_array(count, props, &k_swapchain_ext, 1, sizeof k_swapchain_ext);
    InstanceData *id = instance_for(pd);
    if (layer || !pd_managed(id, pd))
        return id->EnumerateDeviceExtensionProperties(pd, layer, count, props);

    uint32_t n = 0;
    VkResult r = id->EnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
    if (r != VK_SUCCESS) return r;
    VkExtensionProperties *all = calloc(n + 3, sizeof *all);
    r = id->EnumerateDeviceExtensionProperties(pd, NULL, &n, all);
    if (r < 0) { free(all); return r; }
    int lacks_xfb = pd_lacks_xfb(id, pd), have_lson_ext = 0;
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(all[i].extensionName, LSON_EXT)) have_lson_ext = 1;
    uint32_t m = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *e = all[i].extensionName;
        if (stripped(e)) continue;
        if ((single_texel_for(id, pd) || g_test_texel_align) && !strcmp(e, "VK_EXT_descriptor_buffer")) continue;
        /* the loader may already list these (declared in our manifest); re-add below */
        if ((lacks_xfb && !strcmp(e, XFB_EXT)) || !strcmp(e, LSON_KHR)) continue;
        all[m++] = all[i];
    }
    all[m++] = k_swapchain_ext;
    if (lacks_xfb && id->fake) {
        VkExtensionProperties x = {XFB_EXT, 1};
        all[m++] = x;
    }
    if (have_lson_ext) {
        VkExtensionProperties l = {LSON_KHR, 1};
        all[m++] = l;
    }
    r = fill_array(count, props, all, m, sizeof *all);
    free(all);
    return r;
}

/* ------------------------------------------------------- device create */

static PFN_vkVoidFunction bp_GetDeviceProcAddr_impl(DeviceData *dd, const char *name);

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateDevice(
    VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *dev) {
    VkLayerDeviceCreateInfo *link = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerDeviceCreateInfo *)link->pNext;
    if (!link) return VK_ERROR_INITIALIZATION_FAILED;
    VkLayerDeviceCreateInfo *cb = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (cb && !(cb->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && cb->function == VK_LOADER_DATA_CALLBACK))
        cb = (VkLayerDeviceCreateInfo *)cb->pNext;

    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;

    InstanceData *id = instance_for(pd);
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(id->instance, "vkCreateDevice");
    int managed = pd_managed(id, pd);

    VkDeviceCreateInfo ci2 = *ci;
    const char **exts = NULL;
    int app_xfb = 0, lacks_xfb = managed && pd_lacks_xfb(id, pd);
    if (managed) {
        int has_lson_ext = 0;
        for (uint32_t i = 0; i < ci->enabledExtensionCount; i++)
            if (!strcmp(ci->ppEnabledExtensionNames[i], LSON_EXT)) has_lson_ext = 1;
        exts = calloc(ci->enabledExtensionCount + 1, sizeof *exts);
        uint32_t m = 0;
        for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) {
            const char *e = ci->ppEnabledExtensionNames[i];
            if (stripped(e)) continue;
            if ((single_texel_for(id, pd) || g_test_texel_align) && !strcmp(e, "VK_EXT_descriptor_buffer")) continue;
            if (lacks_xfb && !strcmp(e, XFB_EXT)) { app_xfb = 1; continue; }
            if (!strcmp(e, LSON_KHR)) { /* same enums as the EXT the driver has */
                if (!has_lson_ext) { exts[m++] = LSON_EXT; has_lson_ext = 1; }
                continue;
            }
            exts[m++] = e;
        }
        ci2.enabledExtensionCount = m;
        ci2.ppEnabledExtensionNames = exts;
    }

    /* Unlink the stand-in transform feedback feature struct for the call (restored after). */
    VkBaseOutStructure *unl_prev[4], *unl_node[4];
    int nunl = 0;
    if (lacks_xfb) {
        for (VkBaseOutStructure *p = (VkBaseOutStructure *)&ci2; p && p->pNext && nunl < 4;) {
            VkBaseOutStructure *n = p->pNext;
            if (n->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT) {
                unl_prev[nunl] = p; unl_node[nunl] = n; nunl++;
                p->pNext = n->pNext;
                continue;
            }
            p = n;
        }
    }

    /* Drop the spoofed features the app enabled: the driver would reject them. */
    uint64_t lacking = 0;
    VkPhysicalDeviceFeatures enabled, saved;
    VkPhysicalDeviceFeatures2 *f2 = NULL;
    if (managed && id->fake) {
        VkPhysicalDeviceFeatures real;
        id->GetPhysicalDeviceFeatures(pd, &real);
        lacking = missing_features(id, &real);
    }
    if (lacking) {
        if (ci->pEnabledFeatures) {
            enabled = *ci->pEnabledFeatures;
            set_features(&enabled, lacking, VK_FALSE);
            ci2.pEnabledFeatures = &enabled;
        }
        for (const VkBaseInStructure *s = ci->pNext; s; s = s->pNext)
            if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
                f2 = (VkPhysicalDeviceFeatures2 *)s; /* app's struct: changed for the call, then restored */
                saved = f2->features;
                set_features(&f2->features, lacking, VK_FALSE);
                break;
            }
    }
    VkResult r = create(pd, &ci2, a, dev);
    if (f2) f2->features = saved;
    for (int i = nunl - 1; i >= 0; i--) unl_prev[i]->pNext = unl_node[i];
    free(exts);
    if (r != VK_SUCCESS) {
        fprintf(stderr, "[bottle-present] vkCreateDevice failed: %d\n", r);
        return r;
    }

    DeviceData *dd = calloc(1, sizeof *dd);
    dd->device = *dev;
    dd->pd = pd;
    dd->id = id;
    dd->managed = managed;
    dd->fake_xfb = app_xfb;
    if (app_xfb) fprintf(stderr, "[bottle-present] " XFB_EXT " stand-in active (stream output is ignored)\n");
    if (managed) {
        VkPhysicalDeviceProperties pr;
        id->GetPhysicalDeviceProperties(pd, &pr);
        dd->max_texels = pr.limits.maxTexelBufferElements;
    }
    if (managed && (single_texel_for(id, pd) || g_test_texel_align)) {
        VkPhysicalDeviceProperties pr;
        id->GetPhysicalDeviceProperties(pd, &pr);
        dd->texel_check = g_test_texel_align ? g_test_texel_align : (unsigned)pr.limits.minTexelBufferOffsetAlignment;
        if (dd->texel_check <= 1) dd->texel_check = 0;
    }
    dd->gdpa = gdpa;
    dd->set_loader_data = cb ? cb->u.pfnSetDeviceLoaderData : NULL;
    pthread_mutex_init(&dd->qlock, NULL);
#define DF(n) dd->n = (PFN_vk##n)gdpa(*dev, "vk" #n)
    DF(DestroyDevice); DF(GetDeviceQueue); DF(QueueSubmit); DF(QueueWaitIdle);
    DF(QueueBindSparse); DF(DeviceWaitIdle);
    DF(CreateImage); DF(DestroyImage); DF(GetImageMemoryRequirements);
    DF(AllocateMemory); DF(FreeMemory); DF(BindImageMemory);
    DF(CreateBuffer); DF(DestroyBuffer); DF(GetBufferMemoryRequirements); DF(BindBufferMemory);
    DF(MapMemory); DF(UnmapMemory); DF(InvalidateMappedMemoryRanges);
    DF(CreateCommandPool); DF(DestroyCommandPool); DF(AllocateCommandBuffers);
    DF(BeginCommandBuffer); DF(EndCommandBuffer); DF(CmdPipelineBarrier); DF(CmdCopyImageToBuffer);
    DF(CreateFence); DF(DestroyFence); DF(WaitForFences); DF(ResetFences);
    DF(CmdBeginQuery); DF(CmdEndQuery); DF(GetDeviceBufferMemoryRequirements);
    DF(CreateBufferView); DF(CreateQueryPool);
    DF(CmdDraw); DF(CmdDrawIndexed); DF(CmdDrawIndirect); DF(CmdDrawIndexedIndirect); DF(CmdDispatch);
    DF(CreateGraphicsPipelines); DF(CreateComputePipelines); DF(QueueSubmit2); DF(QueueSubmit2KHR);
    DF(CmdBeginRendering); DF(CmdBeginRenderingKHR); DF(CmdBeginRenderPass); DF(CmdBeginRenderPass2);
    DF(CmdBeginRenderPass2KHR); DF(CmdPipelineBarrier2); DF(CmdPipelineBarrier2KHR);
    if (!dd->GetDeviceBufferMemoryRequirements)
        dd->GetDeviceBufferMemoryRequirements = (PFN_vkGetDeviceBufferMemoryRequirements)gdpa(*dev, "vkGetDeviceBufferMemoryRequirementsKHR");
#undef DF

    if (managed) {
        /* Our own queue for copies and acquire signals: the first queue the app
         * created in a graphics/transfer-capable family. */
        uint32_t nfam = 0;
        id->GetPhysicalDeviceQueueFamilyProperties(pd, &nfam, NULL);
        VkQueueFamilyProperties *fams = calloc(nfam ? nfam : 1, sizeof *fams);
        id->GetPhysicalDeviceQueueFamilyProperties(pd, &nfam, fams);
        dd->qfam = ci->queueCreateInfoCount ? ci->pQueueCreateInfos[0].queueFamilyIndex : 0;
        for (uint32_t i = 0; i < ci->queueCreateInfoCount; i++) {
            uint32_t f = ci->pQueueCreateInfos[i].queueFamilyIndex;
            if (f < nfam && (fams[f].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))) { dd->qfam = f; break; }
        }
        free(fams);
        dd->GetDeviceQueue(*dev, dd->qfam, 0, &dd->queue);
        if (dd->set_loader_data) dd->set_loader_data(*dev, dd->queue);
        VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                       .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                                       .queueFamilyIndex = dd->qfam};
        dd->CreateCommandPool(*dev, &pci, NULL, &dd->pool);
        id->GetPhysicalDeviceMemoryProperties(pd, &dd->memprops);
        LOG("device created, copy queue family %u", dd->qfam);
    }
    map_put(&g_devices, *dev, dd);
    return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL bp_DestroyDevice(VkDevice dev, const VkAllocationCallbacks *a) {
    DeviceData *dd = device_for(dev);
    if (!dd) return;
    if (dd->pool) dd->DestroyCommandPool(dev, dd->pool, NULL);
    PFN_vkDestroyDevice destroy = dd->DestroyDevice;
    map_del(&g_devices, dd->device);
    __atomic_fetch_add(&g_dev_gen, 1, __ATOMIC_RELEASE);
    free(dd);
    destroy(dev, a);
}

/* ------------------------------------------------------- instance create */

/* Where Steam's in-game overlay stands in this game, said once per game in its log: whether
 * its pieces are loaded into the process (gameoverlayrenderer.so by LD_PRELOAD, its Vulkan
 * layer steamoverlayvulkanlayer.so), whether Steam asked for the layer, and what sits right
 * below this layer in the Vulkan chain. An overlay layer has to be ABOVE this one (nearer the
 * game) to see the frames: this layer answers the swapchain calls itself. */
static int overlay_lib_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    char *out = data;
    const char *n = info->dlpi_name;
    if (n && (strstr(n, "gameoverlayrenderer") || strstr(n, "steamoverlayvulkanlayer") || strstr(n, "MangoHud"))) {
        size_t l = strlen(out);
        if (l + strlen(n) + 3 < 1024) { strcat(out, l ? ", " : ""); strcat(out, n); }
    }
    return 0;
}
static void overlay_report(PFN_vkGetInstanceProcAddr next) {
    static int said;
    if (__atomic_exchange_n(&said, 1, __ATOMIC_RELAXED)) return;
    char libs[1024] = "";
    dl_iterate_phdr(overlay_lib_cb, libs);
    Dl_info di;
    const char *below = (next && dladdr((void *)next, &di) && di.dli_fname) ? di.dli_fname : "?";
    const char *e1 = getenv("ENABLE_VK_LAYER_VALVE_steam_overlay_1"), *e2 = getenv("DISABLE_VK_LAYER_VALVE_steam_overlay_1");
    const char *pre = getenv("LD_PRELOAD"), *il = getenv("VK_INSTANCE_LAYERS"), *og = getenv("SteamOverlayGameId");
    LOGA("Steam overlay here (%s): loaded [%s]; its Vulkan layer asked for: ENABLE_VK_LAYER_VALVE_steam_overlay_1=%s"
         " DISABLE_...=%s; SteamOverlayGameId=%s; VK_INSTANCE_LAYERS=%s; LD_PRELOAD=%s; next below this layer: %s",
         g_ov_fwd.state == 1 ? "hosted by this layer" : "not hosted", libs[0] ? libs : "none", e1 ? e1 : "-", e2 ? e2 : "-", og ? og : "-", il ? il : "-", pre ? pre : "-", below);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateInstance(
    const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *inst) {
    init_env();
    VkLayerInstanceCreateInfo *link = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerInstanceCreateInfo *)link->pNext;
    if (!link) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    VkResult r = create(ci, a, inst);
    if (r != VK_SUCCESS) return r;

    InstanceData *id = calloc(1, sizeof *id);
    id->instance = *inst;
    id->gipa = gipa;
#define IF(n) id->n = (PFN_vk##n)gipa(*inst, "vk" #n)
    IF(DestroyInstance); IF(EnumerateDeviceExtensionProperties); IF(GetPhysicalDeviceProperties);
    IF(GetPhysicalDeviceMemoryProperties); IF(GetPhysicalDeviceQueueFamilyProperties);
    IF(GetPhysicalDeviceSurfaceSupportKHR); IF(GetPhysicalDeviceSurfaceCapabilitiesKHR);
    IF(GetPhysicalDeviceSurfaceFormatsKHR); IF(GetPhysicalDeviceSurfacePresentModesKHR);
    IF(GetPhysicalDeviceSurfaceCapabilities2KHR); IF(GetPhysicalDeviceSurfaceFormats2KHR);
    IF(GetPhysicalDevicePresentRectanglesKHR);
    IF(GetPhysicalDeviceXcbPresentationSupportKHR); IF(GetPhysicalDeviceXlibPresentationSupportKHR);
    IF(CreateXcbSurfaceKHR); IF(CreateXlibSurfaceKHR); IF(DestroySurfaceKHR);
    IF(GetPhysicalDeviceFeatures); IF(GetPhysicalDeviceFeatures2); IF(GetPhysicalDeviceFeatures2KHR);
    IF(GetPhysicalDeviceProperties2); IF(GetPhysicalDeviceProperties2KHR);
#undef IF
    const char *engine = ci->pApplicationInfo ? ci->pApplicationInfo->pEngineName : NULL;
    id->fake = g_fake_mode > 0 ||
               (g_fake_mode < 0 && engine && (!strcmp(engine, "DXVK") || !strncmp(engine, "vkd3d", 5)));
    id->fake_mask = g_fake_mask;
    id->vkd3d = engine && !strncmp(engine, "vkd3d", 5);
    const char *fz = getenv("BOTTLE_FAKE_ZINK");
    if (!id->fake && g_fake_mode != 0 && fz && *fz && strcmp(fz, "0") != 0 && engine && !strcmp(engine, "mesa zink")) {
        id->fake = 1;
        id->fake_mask = fake_mask_from(fz);
    }
    if (engine && !strcmp(engine, "mesa zink")) g_no_pace = g_zink = 1; /* Steam's interface, not a game */
    if (!g_zink) overlay_report(gipa);
    map_put(&g_instances, *inst, id);
    LOG("instance created (engine %s, feature spoofing %s)", engine ? engine : "-", id->fake ? "on" : "off");
    return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL bp_DestroyInstance(VkInstance inst, const VkAllocationCallbacks *a) {
    InstanceData *id = instance_for(inst);
    if (!id) return;
    PFN_vkDestroyInstance destroy = id->DestroyInstance;
    map_del(&g_instances, id->instance);
    free(id);
    destroy(inst, a);
}

/* ------------------------------------------------------------ proc addrs */

#define MATCH(fn) if (!strcmp(name, "vk" #fn)) return (PFN_vkVoidFunction)bp_##fn

static PFN_vkVoidFunction swapchain_proc(const char *name) {
    MATCH(CreateSwapchainKHR);
    MATCH(DestroySwapchainKHR);
    MATCH(GetSwapchainImagesKHR);
    MATCH(AcquireNextImageKHR);
    MATCH(AcquireNextImage2KHR);
    MATCH(QueuePresentKHR);
    MATCH(GetDeviceGroupPresentCapabilitiesKHR);
    MATCH(GetDeviceGroupSurfacePresentModesKHR);
    return NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL bp_GDPA_inner(VkDevice dev, const char *name);

static PFN_vkVoidFunction bp_GetDeviceProcAddr_impl(DeviceData *dd, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)bp_GDPA_inner;
    MATCH(DestroyDevice);
    if (dd && dd->managed) {
        PFN_vkVoidFunction f = swapchain_proc(name);
        if (f) return f;
    }
#define MATCH_IF(fn) if (dd->fn && !strcmp(name, "vk" #fn)) return (PFN_vkVoidFunction)bp_##fn
    if (dd && dd->managed) {  /* serialized queue access (see bp_QueueSubmit) */
        MATCH_IF(QueueSubmit); MATCH_IF(QueueSubmit2); MATCH_IF(QueueSubmit2KHR);
        MATCH_IF(QueueWaitIdle); MATCH_IF(QueueBindSparse); MATCH_IF(DeviceWaitIdle);
    }
    /* the pacing line's pipeline counts (cheap), and pipelines created with an answer (games) */
    if (dd && dd->managed && (!g_no_pace || (!g_zink && !g_async_pipes))) {
        MATCH_IF(CreateGraphicsPipelines); MATCH_IF(CreateComputePipelines);
    }
    if (dd && dd->managed && g_debug > 0) {
        MATCH_IF(CmdDraw); MATCH_IF(CmdDrawIndexed); MATCH_IF(CmdDrawIndirect); MATCH_IF(CmdDrawIndexedIndirect);
        MATCH_IF(CmdDispatch); MATCH_IF(CreateGraphicsPipelines); MATCH_IF(CreateComputePipelines);
        MATCH_IF(CmdBeginRendering); MATCH_IF(CmdBeginRenderingKHR); MATCH_IF(CmdBeginRenderPass);
        MATCH_IF(CmdBeginRenderPass2); MATCH_IF(CmdBeginRenderPass2KHR); MATCH_IF(CmdPipelineBarrier);
        MATCH_IF(CmdPipelineBarrier2); MATCH_IF(CmdPipelineBarrier2KHR); MATCH_IF(CmdBeginQuery);
    }
#undef MATCH_IF
    if (dd && dd->fake_xfb) {
        MATCH(CmdBindTransformFeedbackBuffersEXT);
        MATCH(CmdBeginTransformFeedbackEXT);
        MATCH(CmdEndTransformFeedbackEXT);
        MATCH(CmdBeginQueryIndexedEXT);
        MATCH(CmdEndQueryIndexedEXT);
        MATCH(CmdDrawIndirectByteCountEXT);
        MATCH(CreateBuffer);
        if (dd->CreateQueryPool) MATCH(CreateQueryPool);
        MATCH(GetDeviceBufferMemoryRequirements);
        if (!strcmp(name, "vkGetDeviceBufferMemoryRequirementsKHR"))
            return (PFN_vkVoidFunction)bp_GetDeviceBufferMemoryRequirements;
    }
    if (dd && (dd->texel_check || dd->max_texels) && dd->CreateBufferView) MATCH(CreateBufferView);
    return dd ? dd->gdpa(dd->device, name) : NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL bp_GDPA_inner(VkDevice dev, const char *name) {
    return bp_GetDeviceProcAddr_impl(device_for(dev), name);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL bp_GIPA_inner(VkInstance inst, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)bp_GIPA_inner;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)bp_GDPA_inner;
    MATCH(CreateInstance);
    MATCH(DestroyInstance);
    MATCH(CreateDevice);
    MATCH(EnumerateDeviceExtensionProperties);
    MATCH(GetPhysicalDeviceFeatures);
    MATCH(GetPhysicalDeviceFeatures2);
    MATCH(GetPhysicalDeviceFeatures2KHR);
    MATCH(GetPhysicalDeviceProperties2);
    MATCH(GetPhysicalDeviceProperties2KHR);
    MATCH(GetPhysicalDeviceSurfaceSupportKHR);
    MATCH(GetPhysicalDeviceSurfaceCapabilitiesKHR);
    MATCH(GetPhysicalDeviceSurfaceFormatsKHR);
    MATCH(GetPhysicalDeviceSurfacePresentModesKHR);
    MATCH(GetPhysicalDeviceSurfaceCapabilities2KHR);
    MATCH(GetPhysicalDeviceSurfaceFormats2KHR);
    MATCH(GetPhysicalDevicePresentRectanglesKHR);
    MATCH(GetPhysicalDeviceXcbPresentationSupportKHR);
    MATCH(GetPhysicalDeviceXlibPresentationSupportKHR);
    MATCH(CreateXcbSurfaceKHR);
    MATCH(CreateXlibSurfaceKHR);
    MATCH(DestroySurfaceKHR);
    MATCH(DestroyDevice);
    if (!inst) return NULL;
    InstanceData *id = instance_for(inst);
    return id ? id->gipa(inst, name) : NULL;
}

#undef MATCH

/* ---- Steam's in-game overlay, hosted above this layer ----
 * Steam starts each game with its overlay asked for (SteamOverlayGameId, and
 * ENABLE_VK_LAYER_VALVE_steam_overlay_1=1 for its Vulkan layer), but on this ARM64 Steam
 * neither part reaches an x86 game (Oct 10: nothing loaded, LD_PRELOAD empty in the game).
 * Steam's container launcher, pressure-vessel, is the arm64 build here: it can't work out x86
 * library paths (its x86_64 helpers are missing), so it drops the x86 gameoverlayrenderer.so
 * from LD_PRELOAD and the overlay's Vulkan layer from the layers it passes in. Even if the
 * layer got in, it has to sit ABOVE this one to see frames, since this layer answers the
 * swapchain calls itself.
 * So this layer brings the overlay in: in the game's first vkCreateInstance it loads
 * gameoverlayrenderer.so (the part that talks to Steam) and steamoverlayvulkanlayer.so (the
 * part that draws) from Steam's own ubuntu12_64 (or ubuntu12_32), then puts the Vulkan
 * layer in the chain right above itself: the loader calls these outer entry points, they hand
 * every call to the overlay layer, whose "next layer" is this layer's inner entry points.
 * Only when Steam asked for the overlay, never in Steam's own interface (zink), and not when
 * the loader already loaded the overlay layer. BOTTLE_STEAM_OVERLAY=0 turns it off.
 * First try (Oct 10, 18:58): both parts loaded and Steam started its overlay UI process
 * (steamrtarm64/gameoverlayui) for the game, six times in a second, but nothing was drawn. */
static struct {
    int state; /* 0 not decided, 1 hosting, -1 not hosting */
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkGetDeviceProcAddr gdpa;
} g_ov;
static pthread_mutex_t g_ov_lock = PTHREAD_MUTEX_INITIALIZER;

static int ov_loaded_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    if (info->dlpi_name && strstr(info->dlpi_name, "steamoverlayvulkanlayer")) *(int *)data = 1;
    return 0;
}
static void *ov_open(const char *file, int flags, char *where, size_t wlen) {
    const char *arch = sizeof(void *) == 8 ? "ubuntu12_64" : "ubuntu12_32";
    const char *home = getenv("HOME"), *ci = getenv("STEAM_COMPAT_CLIENT_INSTALL_PATH");
    char path[1200];
    for (int k = 0; k < 4; k++) {
        if (k == 0 && ci && *ci) snprintf(path, sizeof path, "%s/%s/%s", ci, arch, file);
        else if (k == 1) snprintf(path, sizeof path, "/s/%s/%s", arch, file);
        else if (k == 2 && home) snprintf(path, sizeof path, "%s/.local/share/Steam/%s/%s", home, arch, file);
        else if (k == 3 && home) snprintf(path, sizeof path, "%s/.steam/steam/%s/%s", home, arch, file);
        else continue;
        void *h = dlopen(path, flags);
        if (h) { snprintf(where, wlen, "%s", path); return h; }
        snprintf(where, wlen, "%s: %s", path, dlerror());
    }
    return NULL;
}
/* ---- what Steam's overlay draws (diagnostics) ----
 * Oct 11: in The Witcher 3 (DirectX 12) Steam's performance monitor came out as a dark band
 * down the left of the screen, full height, with the monitor's graph lines as vertical stripes:
 * a few rows of the overlay's picture stretched over the whole frame. The overlay's renderer
 * (gameoverlayrenderer.so) lays the overlay out in pixels and calls its Vulkan layer to draw
 * each piece: VulkanSteamOverlayDrawTexturedRect(x0, y0, x1, y1, texture, colour, u0, v0, u1,
 * v1, depth, colour2, mode) and VulkanSteamOverlayUpdateTexture(texture, ...) for the pictures.
 * The Vulkan layer hands the renderer these functions as pointers kept in its own data, so this
 * layer swaps those pointers for the wrappers below (once, when it brings the overlay in): each
 * logs its first 40 calls and then one in 3000, with the frame's size. A full-frame piece
 * taller than the frame (top left at 0,0, as wide as the frame, more than 8 rows taller) is
 * fitted to the frame and said once: that is the stretch above. BOTTLE_OVERLAY_TRACE=0 turns
 * all of it off. */
typedef int (*ov_rect_fn)(int, int, int, int, int, uint32_t, float, float, float, float, float, uint32_t, int);
typedef int (*ov_tex_fn)(long, long, long, long, long, long, long, long, long, long);
static ov_rect_fn g_ov_rect;
static ov_tex_fn g_ov_tex;
static unsigned g_ov_nrect, g_ov_ntex, g_ov_nodd;

static int ov_rect_wrap(int x0, int y0, int x1, int y1, int tex, uint32_t c0, float u0, float v0, float u1, float v1,
                        float z, uint32_t c1, int mode) {
    unsigned n = __atomic_add_fetch(&g_ov_nrect, 1, __ATOMIC_RELAXED);
    int fw = (int)__atomic_load_n(&g_ov_fw, __ATOMIC_RELAXED), fh = (int)__atomic_load_n(&g_ov_fh, __ATOMIC_RELAXED);
    int odd = fw > 0 && fh > 0 && (y1 - y0 > fh + 8 || x1 - x0 > fw + 8 || y0 > fh || x0 > fw ||
                                   (y1 > y0 + 64 && v1 - v0 < 0.01f && v1 - v0 > -0.01f));
    if (n <= 40 || n % 3000 == 0 || (odd && __atomic_add_fetch(&g_ov_nodd, 1, __ATOMIC_RELAXED) <= 40))
        LOGA("overlay rect #%u%s: (%d,%d)-(%d,%d) texture %d uv (%.4f,%.4f)-(%.4f,%.4f) depth %.2f colours %08x %08x mode %d; frame %dx%d",
             n, odd ? " (odd)" : "", x0, y0, x1, y1, tex, u0, v0, u1, v1, z, c0, c1, mode, fw, fh);
    if (x0 == 0 && y0 == 0 && fw > 0 && fh > 0 && x1 == fw && y1 > fh + 8) {
        static int told;
        if (!__atomic_exchange_n(&told, 1, __ATOMIC_RELAXED))
            LOGA("Steam overlay: its full-frame layer came %d rows tall for a %dx%d frame; fitted to the frame", y1, fw, fh);
        y1 = fh;
    }
    return g_ov_rect(x0, y0, x1, y1, tex, c0, u0, v0, u1, v1, z, c1, mode);
}
static int ov_tex_wrap(long a, long b, long c, long d, long e, long f, long s0, long s1, long s2, long s3) {
    unsigned n = __atomic_add_fetch(&g_ov_ntex, 1, __ATOMIC_RELAXED);
    if (n <= 40 || n % 3000 == 0)
        LOGA("overlay texture update #%u: %ld %ld %ld %ld %ld %ld | %ld %#lx %ld %ld", n, (long)(int)a, (long)(int)b,
             (long)(int)c, (long)(int)d, (long)(int)e, (long)(int)f, s0, (unsigned long)s1, s2, s3);
    return g_ov_tex(a, b, c, d, e, f, s0, s1, s2, s3);
}
struct ov_swap { void *from, *to; int n; };
static int ov_swap_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    struct ov_swap *s = data;
    if (!info->dlpi_name || !strstr(info->dlpi_name, "steamoverlayvulkanlayer")) return 0;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_W)) continue;   /* data (read-only after relocation or not) */
        uintptr_t lo = (info->dlpi_addr + ph->p_vaddr + 7) & ~(uintptr_t)7, hi = info->dlpi_addr + ph->p_vaddr + ph->p_memsz;
        for (uintptr_t a = lo; a + sizeof(void *) <= hi; a += sizeof(void *)) {
            if (*(void *volatile *)a != s->from) continue;
            uintptr_t pg = a & ~(uintptr_t)4095;
            if (mprotect((void *)pg, 4096, PROT_READ | PROT_WRITE) == 0) { *(void **)a = s->to; s->n++; }
        }
    }
    return 1;
}
static void ov_trace(void *layer) {
    const char *t = getenv("BOTTLE_OVERLAY_TRACE");
    if (t && *t == '0') return;
    void *rect = dlsym(layer, "VulkanSteamOverlayDrawTexturedRect"), *tex = dlsym(layer, "VulkanSteamOverlayUpdateTexture");
    struct ov_swap a = {rect, (void *)ov_rect_wrap, 0}, b = {tex, (void *)ov_tex_wrap, 0};
    if (rect) { g_ov_rect = (ov_rect_fn)rect; dl_iterate_phdr(ov_swap_cb, &a); }
    if (tex) { g_ov_tex = (ov_tex_fn)tex; dl_iterate_phdr(ov_swap_cb, &b); }
    LOGA("Steam overlay: tracing what it draws (%d rect and %d texture pointers swapped)", a.n, b.n);
}

static void ov_decide(void) {
    pthread_mutex_lock(&g_ov_lock);
    if (g_ov.state) { pthread_mutex_unlock(&g_ov_lock); return; }
    g_ov.state = -1;
    const char *off = getenv("BOTTLE_STEAM_OVERLAY"), *en = getenv("ENABLE_VK_LAYER_VALVE_steam_overlay_1");
    const char *dis = getenv("DISABLE_VK_LAYER_VALVE_steam_overlay_1"), *gid = getenv("SteamOverlayGameId");
    int already = 0;
    dl_iterate_phdr(ov_loaded_cb, &already);
    if ((off && *off == '0') || !en || strcmp(en, "1") || (dis && *dis == '1') || !gid || !*gid || already) {
        pthread_mutex_unlock(&g_ov_lock);
        return;
    }
    char w1[1300] = "", w2[1300] = "";
    void *r = ov_open("gameoverlayrenderer.so", RTLD_NOW | RTLD_GLOBAL, w1, sizeof w1);
    void *l = r ? ov_open("steamoverlayvulkanlayer.so", RTLD_NOW | RTLD_LOCAL, w2, sizeof w2) : NULL;
    if (l) {
        PFN_vkNegotiateLoaderLayerInterfaceVersion neg =
            (PFN_vkNegotiateLoaderLayerInterfaceVersion)dlsym(l, "vkNegotiateLoaderLayerInterfaceVersion");
        if (neg) {
            VkNegotiateLayerInterface ni = {.sType = LAYER_NEGOTIATE_INTERFACE_STRUCT, .loaderLayerInterfaceVersion = 2};
            if (neg(&ni) == VK_SUCCESS) { g_ov.gipa = ni.pfnGetInstanceProcAddr; g_ov.gdpa = ni.pfnGetDeviceProcAddr; }
        }
        if (!g_ov.gipa) g_ov.gipa = (PFN_vkGetInstanceProcAddr)dlsym(l, "vkGetInstanceProcAddr");
        if (!g_ov.gdpa) g_ov.gdpa = (PFN_vkGetDeviceProcAddr)dlsym(l, "vkGetDeviceProcAddr");
    }
    if (g_ov.gipa && g_ov.gdpa) {
        g_ov.state = 1;
        g_ov_fwd.state = 1;
        LOGA("Steam overlay: brought into the game (%s, %s), its Vulkan layer above this one", w1, w2);
        ov_trace(l);
    } else {
        LOGA("Steam overlay: couldn't bring it in (renderer: %s; layer: %s)", w1[0] ? w1 : "-", w2[0] ? w2 : "-");
    }
    pthread_mutex_unlock(&g_ov_lock);
}

static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateInstance_outer(
    const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *a, VkInstance *inst) {
    init_env();
    const char *engine = ci->pApplicationInfo ? ci->pApplicationInfo->pEngineName : NULL;
    if (!(engine && !strcmp(engine, "mesa zink"))) ov_decide();
    if (g_ov.state != 1) return bp_CreateInstance(ci, a, inst);
    VkLayerInstanceCreateInfo *link = (VkLayerInstanceCreateInfo *)ci->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerInstanceCreateInfo *)link->pNext;
    PFN_vkCreateInstance ovc = (PFN_vkCreateInstance)g_ov.gipa(VK_NULL_HANDLE, "vkCreateInstance");
    if (!link || !ovc) return bp_CreateInstance(ci, a, inst);
    VkLayerInstanceLink *mine = link->u.pLayerInfo;
    VkLayerInstanceLink ovl = {.pNext = mine, .pfnNextGetInstanceProcAddr = bp_GIPA_inner, .pfnNextGetPhysicalDeviceProcAddr = NULL};
    link->u.pLayerInfo = &ovl;
    VkResult r = ovc(ci, a, inst);
    if (r != VK_SUCCESS) {
        LOGA("Steam overlay: its vkCreateInstance failed (%d); going on without it", (int)r);
        link->u.pLayerInfo = mine;
        return bp_CreateInstance(ci, a, inst);
    }
    return r;
}
static VKAPI_ATTR VkResult VKAPI_CALL bp_CreateDevice_outer(
    VkPhysicalDevice pd, const VkDeviceCreateInfo *ci, const VkAllocationCallbacks *a, VkDevice *dev) {
    if (g_ov.state != 1) return bp_CreateDevice(pd, ci, a, dev);
    VkLayerDeviceCreateInfo *link = (VkLayerDeviceCreateInfo *)ci->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerDeviceCreateInfo *)link->pNext;
    InstanceData *id = instance_for(pd);
    PFN_vkCreateDevice ovc = id ? (PFN_vkCreateDevice)g_ov.gipa(id->instance, "vkCreateDevice") : NULL;
    if (!link || !ovc) return bp_CreateDevice(pd, ci, a, dev);
    VkLayerDeviceLink *mine = link->u.pLayerInfo;
    VkLayerDeviceLink ovl = {.pNext = mine, .pfnNextGetInstanceProcAddr = bp_GIPA_inner, .pfnNextGetDeviceProcAddr = bp_GDPA_inner};
    link->u.pLayerInfo = &ovl;
    VkResult r = ovc(pd, ci, a, dev);
    if (r != VK_SUCCESS) {
        LOGA("Steam overlay: its vkCreateDevice failed (%d); this device goes on without it", (int)r);
        link->u.pLayerInfo = mine;
        return bp_CreateDevice(pd, ci, a, dev);
    }
    return r;
}

/* What the loader calls. Without the hosted overlay these are the inner entry points. */
EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL bp_GetDeviceProcAddr(VkDevice dev, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)bp_GetDeviceProcAddr;
    if (g_ov.state == 1) return g_ov.gdpa(dev, name);
    return bp_GDPA_inner(dev, name);
}
EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL bp_GetInstanceProcAddr(VkInstance inst, const char *name) {
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)bp_GetInstanceProcAddr;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)bp_GetDeviceProcAddr;
    if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)bp_CreateInstance_outer;
    if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)bp_CreateDevice_outer;
    if (g_ov.state == 1 && inst) return g_ov.gipa(inst, name);
    return bp_GIPA_inner(inst, name);
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *p) {
    init_env();
    if (p->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
    p->loaderLayerInterfaceVersion = 2;
    p->pfnGetInstanceProcAddr = bp_GetInstanceProcAddr;
    p->pfnGetDeviceProcAddr = bp_GetDeviceProcAddr;
    p->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
