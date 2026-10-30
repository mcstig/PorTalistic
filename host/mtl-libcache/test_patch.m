// Compiles logs/bad_vertex.metal as KosmicKrisp wrote it, then with the lane id worked out in the
// function instead of asked for as an input (which Metal refuses in a vertex function).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = (MTLLanguageVersion)262144;
        NSError *e = nil;
        id l = [dev newLibraryWithSource:src options:o error:&e];
        printf("as written: %s\n", l ? "ok" : [[e.localizedDescription substringToIndex:MIN(200u, e.localizedDescription.length)] UTF8String]);
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\n\\s*uint (\\w+) \\[\\[thread_index_in_simdgroup\\]\\],?" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:src options:0 range:NSMakeRange(0, src.length)];
        if (!m) { printf("no lane-id input found\n"); return 1; }
        NSString *name = [src substringWithRange:[m rangeAtIndex:1]];
        NSMutableString *p = [src mutableCopy];
        [p deleteCharactersInRange:m.range];
        NSRange body = [p rangeOfString:@"\n{\n" options:0 range:NSMakeRange(m.range.location, p.length - m.range.location)];
        [p insertString:[NSString stringWithFormat:@"\n    uint %@ = simd_prefix_exclusive_sum(1u);", name] atIndex:body.location + 2];
        e = nil; l = [dev newLibraryWithSource:p options:o error:&e];
        printf("patched: %s\n", l ? "ok" : [[e.localizedDescription substringToIndex:MIN(400u, e.localizedDescription.length)] UTF8String]);
        if (l) {
            id<MTLFunction> f = [l newFunctionWithName:@"main_entrypoint"];
            printf("function: %s\n", f ? "ok" : "missing");
        }
    }
    return 0;
}
