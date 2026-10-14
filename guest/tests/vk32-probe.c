/* vk32-probe: a 32-bit x86 Vulkan program for the bottle's x86 side (run under FEX).
 *
 * Blades of Time (GOG, 32-bit) died when the 32-bit Mesa Venus driver in the x86 system (stock, not
 * Mac-patched) couldn't map its buffers ("mmap failed ... Invalid argument"). This does what a 32-bit game
 * needs first: make an instance, find the GPU, make a device, allocate and map host-visible memory.
 *
 * Build:  gcc -m32 -O2 -o vk32-probe vk32-probe.c -ldl     (the Vulkan headers only; no 32-bit loader needed)
 * Run:    FEX_ROOTFS=/usr/share/guestos/fex-mesa DISPLAY=:1 FEXInterpreter ./vk32-probe   (prints PASS or FAIL)
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define STEP(name) do { printf("%-36s", name); fflush(stdout); } while (0)
#define OK(msg) printf("ok %s\n", msg)
#define FAIL(msg, r) do { printf("FAILED %s (%d)\nFAIL\n", msg, (int)(r)); return 1; } while (0)

/* ---- "dxvk" mode: which device extension / feature set makes vkCreateDevice fail? --------------------------------
 * DXVK (and Wine's winevulkan under it) ask for ~15 device extensions and a long feature chain; Blades of Time got
 * "vkCreateDevice: Failed to create device chain" from this driver with that request. This tries them one by one. */
typedef struct { VkStructureType sType; void *pNext; } Hdr;
static const char *CANDIDATES[] = {
    "VK_KHR_swapchain", "VK_KHR_swapchain_mutable_format", "VK_EXT_swapchain_maintenance1", "VK_KHR_present_id",
    "VK_KHR_present_wait", "VK_EXT_depth_clip_enable", "VK_EXT_hdr_metadata", "VK_EXT_line_rasterization",
    "VK_EXT_multi_draw", "VK_EXT_robustness2", "VK_EXT_shader_stencil_export", "VK_EXT_vertex_attribute_divisor",
    /* what Wine uses to stand in for the Windows-only ones DXVK asks for */
    "VK_KHR_external_memory", "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf", "VK_KHR_external_semaphore",
    "VK_KHR_external_semaphore_fd", "VK_KHR_external_fence", "VK_KHR_external_fence_fd", "VK_KHR_timeline_semaphore",
    "VK_KHR_dedicated_allocation", "VK_KHR_get_memory_requirements2", "VK_EXT_image_drm_format_modifier",
};
#define NCAND (sizeof CANDIDATES / sizeof CANDIDATES[0])

static int dxvk_mode(PFN_vkGetInstanceProcAddr gipa, VkInstance inst, VkPhysicalDevice gpu, uint32_t fam) {
    PFN_vkEnumerateDeviceExtensionProperties enumExt = (PFN_vkEnumerateDeviceExtensionProperties)gipa(inst, "vkEnumerateDeviceExtensionProperties");
    PFN_vkGetPhysicalDeviceFeatures2 getF2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(inst, "vkGetPhysicalDeviceFeatures2");
    PFN_vkCreateDevice createDevice = (PFN_vkCreateDevice)gipa(inst, "vkCreateDevice");
    PFN_vkGetDeviceProcAddr getDevProc = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");

    uint32_t n = 0;
    enumExt(gpu, NULL, &n, NULL);
    VkExtensionProperties *props = calloc(n, sizeof *props);
    enumExt(gpu, NULL, &n, props);
    printf("device extensions the driver offers (%u):", n);
    for (uint32_t i = 0; i < n; i++) printf("%s%s", i % 4 ? " " : "\n  ", props[i].extensionName);
    printf("\n");
    int sup[NCAND];
    const char *use[NCAND];
    uint32_t nuse = 0;
    for (unsigned c = 0; c < NCAND; c++) {
        sup[c] = 0;
        for (uint32_t i = 0; i < n; i++) if (!strcmp(props[i].extensionName, CANDIDATES[c])) sup[c] = 1;
        if (sup[c]) use[nuse++] = CANDIDATES[c];
        else printf("not offered: %s\n", CANDIDATES[c]);
    }

    /* the feature structs, each tied to the extension that makes it valid (NULL = core) */
    static VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    static VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    static VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    static VkPhysicalDeviceDepthClipEnableFeaturesEXT fdc = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT };
    static VkPhysicalDeviceLineRasterizationFeaturesEXT fln = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LINE_RASTERIZATION_FEATURES_EXT };
    static VkPhysicalDeviceMultiDrawFeaturesEXT fmd = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTI_DRAW_FEATURES_EXT };
    static VkPhysicalDeviceRobustness2FeaturesEXT frb = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
    static VkPhysicalDeviceVertexAttributeDivisorFeaturesEXT fva = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_ATTRIBUTE_DIVISOR_FEATURES_EXT };
    static VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT fsm = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT };
    static VkPhysicalDevicePresentIdFeaturesKHR fpi = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR };
    static VkPhysicalDevicePresentWaitFeaturesKHR fpw = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR };
    struct { Hdr *h; const char *name; const char *ext; int in; } F[] = {
        { (Hdr *)&f11, "Vulkan11Features", NULL, 0 }, { (Hdr *)&f12, "Vulkan12Features", NULL, 0 },
        { (Hdr *)&f13, "Vulkan13Features", NULL, 0 },
        { (Hdr *)&fdc, "DepthClipEnable", "VK_EXT_depth_clip_enable", 0 }, { (Hdr *)&fln, "LineRasterization", "VK_EXT_line_rasterization", 0 },
        { (Hdr *)&fmd, "MultiDraw", "VK_EXT_multi_draw", 0 }, { (Hdr *)&frb, "Robustness2", "VK_EXT_robustness2", 0 },
        { (Hdr *)&fva, "VertexAttributeDivisor", "VK_EXT_vertex_attribute_divisor", 0 },
        { (Hdr *)&fsm, "SwapchainMaintenance1", "VK_EXT_swapchain_maintenance1", 0 },
        { (Hdr *)&fpi, "PresentId", "VK_KHR_present_id", 0 }, { (Hdr *)&fpw, "PresentWait", "VK_KHR_present_wait", 0 },
    };
    const int NF = sizeof F / sizeof F[0];
    for (int i = 0; i < NF; i++) {
        F[i].in = 1;
        if (F[i].ext) {
            F[i].in = 0;
            for (uint32_t k = 0; k < nuse; k++) if (!strcmp(use[k], F[i].ext)) F[i].in = 1;
        }
    }
    VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
#define LINK(mask) do { void *last = NULL; for (int i = NF - 1; i >= 0; i--) if (F[i].in && ((mask) >> i & 1)) { F[i].h->pNext = last; last = F[i].h; } f2.pNext = last; } while (0)
    unsigned all = (1u << NF) - 1;
    LINK(all);
    getF2(gpu, &f2);   /* everything the driver says it can do */
    printf("reported core features: geometryShader=%d fillModeNonSolid=%d shaderCullDistance=%d (VK32_ENGINE=%s)\n",
           (int)f2.features.geometryShader, (int)f2.features.fillModeNonSolid, (int)f2.features.shaderCullDistance,
           getenv("VK32_ENGINE") ? getenv("VK32_ENGINE") : "-");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = fam, .queueCount = 1, .pQueuePriorities = &prio };
    int bad = 0;
#define TRY(label, extc, extv, mask, withfeat) do { \
        char tag[128]; snprintf(tag, sizeof tag, "%s", label); printf("%-52s", tag); fflush(stdout); \
        LINK(mask); \
        VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = (withfeat) ? (void *)&f2 : NULL, \
            .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = (extc), .ppEnabledExtensionNames = (extv) }; \
        VkDevice d = NULL; VkResult rr = createDevice(gpu, &dci, NULL, &d); \
        if (rr) { printf("FAILED (%d)\n", (int)rr); bad++; } else { printf("ok\n"); \
            PFN_vkDestroyDevice dd = (PFN_vkDestroyDevice)getDevProc(d, "vkDestroyDevice"); if (dd) dd(d, NULL); } \
    } while (0)

    printf("-- one extension at a time\n");
    for (uint32_t k = 0; k < nuse; k++) { const char *e1[1] = { use[k] }; char lb[96]; snprintf(lb, sizeof lb, "  %s", use[k]); TRY(lb, 1, e1, 0, 0); }
    printf("-- all offered candidates together, no features\n");
    TRY("  extensions only", nuse, use, 0, 0);
    printf("-- with every feature the driver reports\n");
    TRY("  all extensions + all features", nuse, use, all, 1);
    TRY("  no extensions + all features (core structs only)", 0, NULL, 7, 1);
    printf("-- all extensions and features, but one feature struct left out\n");
    for (int i = 0; i < NF; i++) {
        if (!F[i].in) continue;
        char lb[96]; snprintf(lb, sizeof lb, "  without %s", F[i].name);
        TRY(lb, nuse, use, all & ~(1u << i), 1);
    }
    printf("-- one feature struct at a time (with its extension)\n");
    for (int i = 0; i < NF; i++) {
        if (!F[i].in) continue;
        char lb[96]; snprintf(lb, sizeof lb, "  only %s", F[i].name);
        const char *e1[1] = { F[i].ext };
        TRY(lb, F[i].ext ? 1 : 0, e1, 1u << i, 1);
    }
    printf("%s (%d failures)\n", bad ? "DXVK-LIKE FAIL" : "DXVK-LIKE PASS", bad);
    return bad != 0;
}

int main(int argc, char **argv) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) { printf("no libvulkan.so.1: %s\nFAIL\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance createInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");

    {
        PFN_vkEnumerateInstanceLayerProperties enumLayers = (PFN_vkEnumerateInstanceLayerProperties)gipa(NULL, "vkEnumerateInstanceLayerProperties");
        uint32_t nl = 0;
        if (enumLayers && !enumLayers(&nl, NULL) && nl) {
            VkLayerProperties *lp = calloc(nl, sizeof *lp);
            enumLayers(&nl, lp);
            printf("instance layers the loader knows (%u):", nl);
            for (uint32_t i = 0; i < nl; i++) printf(" %s", lp[i].layerName);
            printf("\n");
        } else printf("instance layers the loader knows: none\n");
    }
    STEP("vkCreateInstance");
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk32-probe", .pEngineName = getenv("VK32_ENGINE"), .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    VkResult r = createInstance(&ici, NULL, &inst);
    if (r) FAIL("vkCreateInstance", r);
    OK("");

    PFN_vkEnumeratePhysicalDevices enumPhys = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties getProps = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    PFN_vkGetPhysicalDeviceMemoryProperties getMem = (PFN_vkGetPhysicalDeviceMemoryProperties)gipa(inst, "vkGetPhysicalDeviceMemoryProperties");
    PFN_vkGetPhysicalDeviceQueueFamilyProperties getQf = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)gipa(inst, "vkGetPhysicalDeviceQueueFamilyProperties");
    PFN_vkCreateDevice createDevice = (PFN_vkCreateDevice)gipa(inst, "vkCreateDevice");
    PFN_vkGetDeviceProcAddr getDevProc = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");

    STEP("vkEnumeratePhysicalDevices");
    uint32_t n = 0;
    r = enumPhys(inst, &n, NULL);
    if (r || !n) FAIL("no physical device", r);
    VkPhysicalDevice devs[8];
    if (n > 8) n = 8;
    r = enumPhys(inst, &n, devs);
    if (r < 0) FAIL("vkEnumeratePhysicalDevices", r);
    VkPhysicalDevice gpu = devs[0];
    int found = 0;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        getProps(devs[i], &p);
        printf("%s%s (type %d, api %u.%u.%u)", i ? ", " : "", p.deviceName, p.deviceType,
               VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion));
        if (p.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU && !found) { gpu = devs[i]; found = 1; }
    }
    printf("\n");

    STEP("vkCreateDevice");
    uint32_t nq = 0;
    getQf(gpu, &nq, NULL);
    VkQueueFamilyProperties qf[16];
    if (nq > 16) nq = 16;
    getQf(gpu, &nq, qf);
    uint32_t fam = 0;
    for (uint32_t i = 0; i < nq; i++) if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { fam = i; break; }
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = fam, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice dev;
    r = createDevice(gpu, &dci, NULL, &dev);
    if (r) FAIL("vkCreateDevice", r);
    OK("");

    PFN_vkAllocateMemory allocMem = (PFN_vkAllocateMemory)getDevProc(dev, "vkAllocateMemory");
    PFN_vkMapMemory mapMem = (PFN_vkMapMemory)getDevProc(dev, "vkMapMemory");
    PFN_vkUnmapMemory unmapMem = (PFN_vkUnmapMemory)getDevProc(dev, "vkUnmapMemory");
    PFN_vkFreeMemory freeMem = (PFN_vkFreeMemory)getDevProc(dev, "vkFreeMemory");

    VkPhysicalDeviceMemoryProperties mp;
    getMem(gpu, &mp);
    uint32_t type = ~0u;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((mp.memoryTypes[i].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) { type = i; break; }
    if (type == ~0u) FAIL("no host-visible memory type", 0);

    /* sizes that are not multiples of 16 KiB too: the stock driver failed on 131268 bytes */
    static const VkDeviceSize sizes[] = { 131268, 4096, 1 << 20, 64 << 20 };
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        char what[64];
        snprintf(what, sizeof what, "allocate+map %llu bytes", (unsigned long long)sizes[i]);
        STEP(what);
        VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = sizes[i], .memoryTypeIndex = type };
        VkDeviceMemory mem;
        r = allocMem(dev, &mai, NULL, &mem);
        if (r) FAIL("vkAllocateMemory", r);
        void *p = NULL;
        r = mapMem(dev, mem, 0, VK_WHOLE_SIZE, 0, &p);
        if (r || !p) FAIL("vkMapMemory", r);
        memset(p, 0xA5, (size_t)(sizes[i] < (1 << 20) ? sizes[i] : (1 << 20)));
        if (((unsigned char *)p)[0] != 0xA5) FAIL("memory did not hold the data", 0);
        unmapMem(dev, mem);
        freeMem(dev, mem, NULL);
        OK("");
    }
    printf("PASS\n");
    if (argc > 1 && !strcmp(argv[1], "dxvk")) return dxvk_mode(gipa, inst, gpu, fam);
    return 0;
}
