/* vk-probe: tiny Vulkan check that needs nothing but libvulkan.so.1.
 * Prints instance layers, GPUs, API version, and whether VK_KHR_swapchain and the
 * features DXVK/zink care about are present. Built for x86_64 to test the x86 stack
 * that Proton uses under FEX.
 * SPDX-License-Identifier: MIT */
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!lib) { printf("libvulkan.so.1: %s\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
#define G(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
    VkInstance inst = VK_NULL_HANDLE;
    G(vkEnumerateInstanceLayerProperties);
    G(vkCreateInstance);

    uint32_t nl = 0;
    vkEnumerateInstanceLayerProperties(&nl, NULL);
    VkLayerProperties *lp = calloc(nl ? nl : 1, sizeof *lp);
    vkEnumerateInstanceLayerProperties(&nl, lp);
    printf("instance layers (%u):", nl);
    for (uint32_t i = 0; i < nl; i++) printf(" %s", lp[i].layerName);
    printf("\n");

    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkResult r = vkCreateInstance(&ci, NULL, &inst);
    if (r) { printf("vkCreateInstance failed: %d\n", r); return 1; }
    G(vkEnumeratePhysicalDevices);
    G(vkGetPhysicalDeviceProperties);
    G(vkEnumerateDeviceExtensionProperties);
    G(vkGetPhysicalDeviceFeatures2);

    uint32_t nd = 0;
    vkEnumeratePhysicalDevices(inst, &nd, NULL);
    VkPhysicalDevice *pd = calloc(nd ? nd : 1, sizeof *pd);
    vkEnumeratePhysicalDevices(inst, &nd, pd);
    printf("devices: %u\n", nd);
    for (uint32_t i = 0; i < nd; i++) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(pd[i], &p);
        uint32_t ne = 0;
        vkEnumerateDeviceExtensionProperties(pd[i], NULL, &ne, NULL);
        VkExtensionProperties *ep = calloc(ne ? ne : 1, sizeof *ep);
        vkEnumerateDeviceExtensionProperties(pd[i], NULL, &ne, ep);
        int swap = 0;
        for (uint32_t k = 0; k < ne; k++) if (!strcmp(ep[k].extensionName, "VK_KHR_swapchain")) swap = 1;

        VkPhysicalDeviceRobustness2FeaturesEXT rb = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
        VkPhysicalDeviceFeatures2 f2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &rb};
        if (vkGetPhysicalDeviceFeatures2) vkGetPhysicalDeviceFeatures2(pd[i], &f2);
        printf("  GPU %u: %s  Vulkan %u.%u  swapchain=%s  geometryShader=%u  nullDescriptor=%u\n",
               i, p.deviceName, VK_API_VERSION_MAJOR(p.apiVersion), VK_API_VERSION_MINOR(p.apiVersion),
               swap ? "yes" : "NO", f2.features.geometryShader, rb.nullDescriptor);
        free(ep);
    }
    return 0;
}
