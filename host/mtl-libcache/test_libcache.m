// host/tests/mac-mtlcache*.sh: compiles the same Metal source a few times with and without the cache.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
        for (int i = 0; i < 400; i++)
            [src appendFormat:@"float f%d(float x) { return sin(x * %d.0) + cos(x / %d.5) * fma(x, x, %d.25); }\n", i, i + 1, i + 2, i];
        [src appendString:@"kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { float v = o[i];"];
        for (int i = 0; i < 400; i++) [src appendFormat:@" v = f%d(v);", i];
        [src appendFormat:@" o[i] = v + %f; }\n", (double)clock()];   // (unique per run: Metal's own cache can't help)
        MTLCompileOptions *opt = [MTLCompileOptions new];
        for (int r = 0; r < 4; r++) {
            double t0 = now(); NSError *e = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opt error:&e];
            id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
            id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&e];
            printf("compile %d: %.3f s, library %p, function %s, pipeline %s\n", r, now() - t0, (__bridge void *)lib, fn ? "ok" : "MISSING", ps ? "ok" : "FAILED");
        }
        MTLCompileOptions *opt2 = [MTLCompileOptions new]; opt2.fastMathEnabled = !opt.fastMathEnabled;
        double t0 = now(); id<MTLLibrary> l2 = [dev newLibraryWithSource:src options:opt2 error:nil];
        printf("other options: %.3f s, library %p (must be a new one)\n", now() - t0, (__bridge void *)l2);
    }
    return 0;
}
