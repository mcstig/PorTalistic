// logs/bad_vertex.metal (a vertex shader KosmicKrisp wrote, which Metal refuses) twice, and a
// broken source twice: run with the library cache loaded.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = (MTLLanguageVersion)262144;
        for (int r = 0; r < 2; r++) {
            NSError *e = nil; double t0 = now();
            id<MTLLibrary> l = [dev newLibraryWithSource:src options:o error:&e];
            id<MTLFunction> f = [l newFunctionWithName:@"main_entrypoint"];
            printf("vertex shader %d: %.3f s, %s\n", r, now() - t0, l && f ? "compiled" : [e.localizedDescription substringToIndex:MIN(120u, e.localizedDescription.length)].UTF8String);
        }
        for (int r = 0; r < 2; r++) {
            NSError *e = nil; double t0 = now();
            id l = [dev newLibraryWithSource:@"this is not metal" options:o error:&e];
            printf("broken source %d: %.3f s, %s, error %s\n", r, now() - t0, l ? "COMPILED?" : "refused", e ? "given" : "MISSING");
        }
    }
    return 0;
}
