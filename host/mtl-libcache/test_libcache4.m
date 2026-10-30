// The Metal 4 way KosmicKrisp compiles (MTL4Compiler newLibraryWithDescriptor:error:): the vertex
// shader Metal refuses as written, twice; with the library cache loaded it should compile.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError *e = nil;
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (!comp) { printf("no Metal 4 compiler: %s\n", e.localizedDescription.UTF8String); return 1; }
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = (MTLLanguageVersion)262144;
        for (int r = 0; r < 3; r++) {
            MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new]; d.source = src; d.options = o; d.name = @"test";
            e = nil; double t0 = now();
            id<MTLLibrary> l = [comp newLibraryWithDescriptor:d error:&e];
            printf("Metal 4, vertex shader %d: %.3f s, %s\n", r, now() - t0, l ? "compiled" : [e.localizedDescription substringToIndex:MIN(110u, e.localizedDescription.length)].UTF8String);
        }
    }
    return 0;
}
