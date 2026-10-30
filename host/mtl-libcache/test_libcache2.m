// 30 different sources (like a game's shaders), compiled 3 rounds in turn: how long each round takes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSMutableArray *srcs = [NSMutableArray array];
        double seed = (double)clock();
        for (int s = 0; s < 30; s++) {
            NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
            for (int i = 0; i < 150; i++) [src appendFormat:@"float f%d(float x) { return sin(x * %d.0) + cos(x / %d.5) * fma(x, x, %d.25); }\n", i, i + s, i + 2, i];
            [src appendString:@"kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { float v = o[i];"];
            for (int i = 0; i < 150; i++) [src appendFormat:@" v = f%d(v);", i];
            [src appendFormat:@" o[i] = v + %f; }\n", seed + s];
            [srcs addObject:src];
        }
        MTLCompileOptions *opt = [MTLCompileOptions new];
        for (int r = 0; r < 3; r++) {
            double t0 = now(); int ok = 0;
            for (NSString *src in srcs) { NSError *e = nil; id<MTLLibrary> l = [dev newLibraryWithSource:src options:opt error:&e]; if (l) ok++; }
            printf("round %d: %.2f s for %d libraries\n", r, now() - t0, ok);
        }
    }
    return 0;
}
