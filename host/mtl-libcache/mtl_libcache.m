// Portalistic — a cache of compiled Metal libraries inside krunkit (the Mac side of the VM).
//
// KosmicKrisp (the Vulkan driver on Metal) turns every Vulkan pipeline's shaders into Metal source
// and compiles it with -[MTLDevice newLibraryWithSource:options:error:], synchronously, on the
// thread that serves the game's pipeline requests. Games make many pipelines from the same shaders
// (one per blend mode, format, ...): in CS2's Advanced Video menu (Oct 27) 3950 compiles were of
// 87 distinct sources, the same one up to 550 times, about 0.2 s each, the game waiting on every
// one. Metal's own shader cache didn't save that. This keeps each library the first compile made
// and hands it out again for the same source and options; a library can serve any number of
// pipelines.
//
// It also mends one thing KosmicKrisp gets wrong: a vertex shader that uses subgroup operations
// gets its lane number as a [[thread_index_in_simdgroup]] input, which Metal allows in kernels and
// fragment functions but refuses in a vertex function ("invalid 'thread_index_in_simdgroup'
// attribute for input declaration in a vertex function"; CS2, Oct 27: about 2200 such failed
// compiles in minutes, each as slow as a good one, asked for again and again since the pipeline
// never got made). Here the lane number is worked out inside the function instead
// (simd_prefix_exclusive_sum(1u): the lane's place among the active lanes, the same number when
// the simdgroup is full). A compile that still fails is remembered too, and its error given back
// at once the next time.
//
// Loaded with DYLD_INSERT_LIBRARIES by host/bottle (vm_start) when built (host/mtl-libcache/
// build.sh). Off with: bottle env --mac PORTALISTIC_MTL_LIBCACHE=0 (then restart the VM).
// Every 500 calls it says how many were reused, on krunkit's log (~/.lima/<vm>/krunkit.log).
// Built without ARC: "new..." methods return an object the caller owns.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef id (*new_lib_fn)(id, SEL, NSString *, MTLCompileOptions *, NSError **);

static NSMutableDictionary *g_cache;     // key -> id<MTLLibrary> (retained by the dictionary)
static NSMutableDictionary *g_orig;      // class name -> original IMP (as NSValue)
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static unsigned long g_calls, g_hits;
static size_t g_max = 4096;              // libraries kept at most (then the cache starts over)

static NSString *options_key(MTLCompileOptions *o) {
    if (!o) return @"-";
    NSMutableString *k = [NSMutableString string];
    for (NSString *p in @[ @"languageVersion", @"fastMathEnabled", @"mathMode", @"mathFloatingPointFunctions",
                            @"preserveInvariance", @"optimizationLevel", @"libraryType", @"installName",
                            @"maxTotalThreadsPerThreadgroup", @"enableLogging" ]) {
        @try { id v = [o valueForKey:p]; [k appendFormat:@"%@=%@;", p, v ?: @""]; }
        @catch (NSException *e) { }
    }
    NSDictionary *m = o.preprocessorMacros;
    if (m.count) {
        for (id key in [[m allKeys] sortedArrayUsingSelector:@selector(compare:)]) [k appendFormat:@"%@:%@,", key, m[key]];
    }
    return k;
}

static NSString *source_key(NSString *src, MTLCompileOptions *opt) {
    NSData *d = [src dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *k = [NSMutableString stringWithCapacity:80];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [k appendFormat:@"%02x", h[i]];
    [k appendFormat:@"|%lu|%@", (unsigned long)d.length, options_key(opt)];
    return k;
}

// The device's class and the class above it both have the method (the subclass's calls super), and
// both are hooked: a call that comes back in through super goes on to the next original up
// (g_level, per thread), and only the outermost call uses the cache.
static __thread Class g_level;
static __thread id g_level_obj;   // (a wrapper device or compiler, Metal's debug layers, calls another object: that one starts afresh)

// A vertex function asking for [[thread_index_in_simdgroup]]: the input taken out, the value made
// at the start of the function. nil when the source doesn't need it.
static int g_mend = 1;   // PORTALISTIC_MTL_MEND=0: no mending (to compare)
static NSString *mend_vertex_lane_id(NSString *src) {
    if (!g_mend || [src rangeOfString:@"[[thread_index_in_simdgroup]]"].location == NSNotFound) return nil;
    static NSRegularExpression *head, *input;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        head = [[NSRegularExpression alloc] initWithPattern:@"\\bvertex\\s+\\w+\\s+\\w+\\s*\\(" options:0 error:nil];
        input = [[NSRegularExpression alloc] initWithPattern:@"\\n[ \\t]*uint (\\w+) \\[\\[thread_index_in_simdgroup\\]\\],?" options:0 error:nil];
    });
    NSTextCheckingResult *h = [head firstMatchInString:src options:0 range:NSMakeRange(0, src.length)];
    if (!h) return nil;
    // (the inputs end at a line of their own, ")": [[buffer(0)]] has parentheses too)
    NSRange params = [src rangeOfString:@"\n)" options:0 range:NSMakeRange(NSMaxRange(h.range), src.length - NSMaxRange(h.range))];
    if (params.location == NSNotFound) return nil;
    NSTextCheckingResult *m = [input firstMatchInString:src options:0 range:NSMakeRange(h.range.location, params.location - h.range.location)];
    if (!m) return nil;
    NSString *name = [src substringWithRange:[m rangeAtIndex:1]];
    NSMutableString *p = [[src mutableCopy] autorelease];
    [p deleteCharactersInRange:m.range];
    // a comma left before the closing parenthesis (the input was the last one)
    NSRange close = [p rangeOfString:@"\n)" options:0 range:NSMakeRange(m.range.location, p.length - m.range.location)];
    NSUInteger k = close.location;
    while (k > 0 && isspace([p characterAtIndex:k - 1])) k--;
    if (k > 0 && [p characterAtIndex:k - 1] == ',') [p deleteCharactersInRange:NSMakeRange(k - 1, 1)];
    NSRange body = [p rangeOfString:@"{" options:0 range:NSMakeRange(m.range.location, p.length - m.range.location)];
    if (body.location == NSNotFound) return nil;
    [p insertString:[NSString stringWithFormat:@"\n    uint %@ = simd_prefix_exclusive_sum(1u);", name] atIndex:body.location + 1];
    return p;
}

static unsigned long g_mended, g_failed_again;

static IMP original_in(NSDictionary *table, Class start, Class *found) {
    IMP f = NULL;
    os_unfair_lock_lock(&g_lock);
    for (Class c = start; c && !f; c = class_getSuperclass(c)) {
        NSValue *v = table[NSStringFromClass(c)];
        if (v) { f = (IMP)[v pointerValue]; *found = c; }
    }
    os_unfair_lock_unlock(&g_lock);
    return f;
}

// The cache itself, for both ways of compiling: the library for KEY from before (or its error),
// or COMPILE's (given the mended source, or nil for the source as it is).
static id from_cache_or(NSString *key, NSString *src, NSError **err, id (^compile)(NSString *mended, NSError **e)) {
    os_unfair_lock_lock(&g_lock);
    id lib = g_cache[key];
    g_calls++;
    if (lib) { g_hits++; [lib retain]; }
    if ([lib isKindOfClass:[NSError class]]) g_failed_again++;
    unsigned long calls = g_calls, hits = g_hits, kept = g_cache.count, n_mended = g_mended, failed = g_failed_again;
    os_unfair_lock_unlock(&g_lock);
    if (calls <= 3)   // (what the keys look like: a reuse needs the same source and options)
        fprintf(stderr, "portalistic mtl-libcache: compile %lu, key %.200s\n", calls, key.UTF8String);
    if (calls % 500 == 0)
        fprintf(stderr, "portalistic mtl-libcache: %lu library compiles asked, %lu answered from the cache (%lu of them failures given back), %lu vertex shaders mended, %lu kept\n",
                calls, hits, failed, n_mended, kept);
    if ([lib isKindOfClass:[NSError class]]) {   // (it failed before: the same error, at once)
        if (err) *err = [[lib retain] autorelease];
        [lib release];
        return nil;
    }
    if (lib) return lib;

    NSString *mended = mend_vertex_lane_id(src);
    NSError *e = nil;
    lib = compile(mended, &e);    // +1 for our caller
    if (err) *err = e;
    os_unfair_lock_lock(&g_lock);
    if (mended && lib) g_mended++;
    if (g_cache.count >= g_max) [g_cache removeAllObjects];
    if (!g_cache[key]) {
        if (lib) g_cache[key] = lib;                  // (the dictionary keeps its own reference)
        else if (e) g_cache[key] = e;
    }
    os_unfair_lock_unlock(&g_lock);
    if (!lib && e) {
        static int shown;
        if (shown++ < 5) fprintf(stderr, "portalistic mtl-libcache: a compile failed%s: %.300s\n", mended ? " (mended)" : "", e.localizedDescription.UTF8String);
    }
    return lib;
}

// -[MTLDevice newLibraryWithSource:options:error:]
static id cached_new_library(id self, SEL cmd, NSString *src, MTLCompileOptions *opt, NSError **err) {
    Class outer = g_level_obj == self ? g_level : Nil, level = Nil;
    id outer_obj = g_level_obj;
    new_lib_fn orig = (new_lib_fn)original_in(g_orig, outer ? class_getSuperclass(outer) : object_getClass(self), &level);
    if (!orig) return nil;
    if (outer || !src) {   // (inside our own call: straight on)
        g_level = level; g_level_obj = self;
        id r = orig(self, cmd, src, opt, err);
        g_level = outer; g_level_obj = outer_obj;
        return r;
    }
    NSString *key = nil;
    @autoreleasepool { key = [[NSString stringWithFormat:@"%p|%@", self, source_key(src, opt)] retain]; }
    Class saved = g_level;
    id lib = from_cache_or(key, src, err, ^id(NSString *mended, NSError **e) {
        g_level = level; g_level_obj = self;
        id r = orig(self, cmd, mended ?: src, opt, e);
        g_level = saved; g_level_obj = outer_obj;
        return r;
    });
    [key release];
    return lib;
}

// -[MTL4Compiler newLibraryWithDescriptor:error:] (macOS 26's Metal 4 compiler, which KosmicKrisp
// uses for its pipelines' shaders): the descriptor carries the source, options and a name
typedef id (*new_lib_desc_fn)(id, SEL, id, NSError **);
static NSMutableDictionary *g_orig4;
static __thread Class g_level4;
static __thread id g_level4_obj;

static id cached_new_library_desc(id self, SEL cmd, id desc, NSError **err) {
    Class outer = g_level4_obj == self ? g_level4 : Nil, level = Nil;
    id outer_obj = g_level4_obj;
    new_lib_desc_fn orig = (new_lib_desc_fn)original_in(g_orig4, outer ? class_getSuperclass(outer) : object_getClass(self), &level);
    if (!orig) return nil;
    NSString *src = nil, *name = nil;
    MTLCompileOptions *opt = nil;
    @try {
        src = [desc valueForKey:@"source"];
        opt = [desc valueForKey:@"options"];
        name = [desc valueForKey:@"name"];
    } @catch (NSException *x) { src = nil; }
    if (outer || ![src isKindOfClass:[NSString class]]) {
        g_level4 = level; g_level4_obj = self;
        id r = orig(self, cmd, desc, err);
        g_level4 = outer; g_level4_obj = outer_obj;
        return r;
    }
    NSString *key = nil;
    @autoreleasepool {
        key = [[NSString stringWithFormat:@"%p|4|%@|%@", self, [name isKindOfClass:[NSString class]] ? name : @"", source_key(src, opt)] retain];
    }
    id lib = from_cache_or(key, src, err, ^id(NSString *mended, NSError **e) {
        id d = desc;
        if (mended) {
            @try { d = [[desc copy] autorelease]; [d setValue:mended forKey:@"source"]; }
            @catch (NSException *x) { d = desc; }
        }
        Class saved = g_level4;
        g_level4 = level; g_level4_obj = self;
        id r = orig(self, cmd, d, e);
        g_level4 = saved; g_level4_obj = outer_obj;
        return r;
    });
    [key release];
    return lib;
}

static int hook_class_sel(Class c, SEL sel, IMP mine, NSMutableDictionary *table) {
    unsigned int mc = 0;
    int hooked = 0;
    Method *ms = class_copyMethodList(c, &mc);
    for (unsigned int j = 0; j < mc; j++) {
        if (method_getName(ms[j]) != sel || method_getImplementation(ms[j]) == mine) continue;
        os_unfair_lock_lock(&g_lock);
        IMP old = method_setImplementation(ms[j], mine);
        table[NSStringFromClass(c)] = [NSValue valueWithPointer:(const void *)old];
        os_unfair_lock_unlock(&g_lock);
        fprintf(stderr, "portalistic mtl-libcache: caching %s's %s\n", class_getName(c), sel_getName(sel));
        hooked++;
    }
    free(ms);
    return hooked;
}
static int hook_class(Class c) {
    return hook_class_sel(c, @selector(newLibraryWithSource:options:error:), (IMP)cached_new_library, g_orig)
         + hook_class_sel(c, @selector(newLibraryWithDescriptor:error:), (IMP)cached_new_library_desc, g_orig4);
}

// every loaded class with its own newLibraryWithDescriptor:error: (the Metal 4 compiler's classes;
// once, when the first device is made, after Metal has loaded the GPU's driver)
static void hook_compilers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int n = 0;
        Class *all = objc_copyClassList(&n);
        for (unsigned int i = 0; i < n; i++)
            hook_class_sel(all[i], @selector(newLibraryWithDescriptor:error:), (IMP)cached_new_library_desc, g_orig4);
        free(all);
    });
}

// The GPU's own device class (AGX...Device) comes with a driver bundle Metal loads when a device is
// first made: hook its class (and the classes above it) on each device the process gets.
static void hook_device(id dev) {
    if (!dev || !g_cache) return;
    for (Class c = object_getClass(dev); c; c = class_getSuperclass(c)) hook_class(c);
    hook_compilers();
}

extern id<MTLDevice> MTLCreateSystemDefaultDevice(void);
extern NSArray *MTLCopyAllDevices(void);
static id<MTLDevice> my_create_default(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    hook_device(d);
    return d;
}
static NSArray *my_copy_all(void) {
    NSArray *a = MTLCopyAllDevices();
    for (id d in a) hook_device(d);
    return a;
}
__attribute__((used, section("__DATA,__interpose"))) static struct { const void *repl, *orig; } interposers[] = {
    { (const void *)my_create_default, (const void *)MTLCreateSystemDefaultDevice },
    { (const void *)my_copy_all, (const void *)MTLCopyAllDevices },
};

__attribute__((constructor)) static void portalistic_mtl_libcache_init(void) {
    const char *off = getenv("PORTALISTIC_MTL_LIBCACHE");
    if (off && strcmp(off, "0") == 0) return;
    const char *mx = getenv("PORTALISTIC_MTL_LIBCACHE_MAX");
    if (mx && atol(mx) > 0) g_max = (size_t)atol(mx);
    const char *md = getenv("PORTALISTIC_MTL_MEND");
    if (md && strcmp(md, "0") == 0) g_mend = 0;
    g_cache = [[NSMutableDictionary alloc] init];
    g_orig = [[NSMutableDictionary alloc] init];
    g_orig4 = [[NSMutableDictionary alloc] init];
    Class base = objc_getClass("_MTLDevice");
    if (base) hook_class(base);
    fprintf(stderr, "portalistic mtl-libcache: on%s\n", g_mend ? "" : " (no mending of vertex shaders)");
}
