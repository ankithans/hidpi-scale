// lsmon.m — list online monitors matched by models.conf, one per line as
// "UUID WxH" (panel resolution). Only exact EDID vendor+model matches are
// printed, so unlisted monitors are never affected.
// With -virtual, prints this project's virtual displays instead (serial order).
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//        -framework ColorSync -o lsmon lsmon.m

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach-o/dyld.h>

// Exported by CoreGraphics but not declared in public headers
CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t displayID);

static const uint32_t kVirtVendor = 0xF0F0;  // our virtual displays
static const uint32_t kVirtModel = 0xD311;

typedef struct { uint32_t vendor, model, pw, ph; } ModelEntry;

static NSString *baseDir(void) {
    char exe[PATH_MAX];
    uint32_t sz = sizeof(exe);
    _NSGetExecutablePath(exe, &sz);
    char real[PATH_MAX];
    realpath(exe, real);
    return [[NSString stringWithUTF8String:real] stringByDeletingLastPathComponent];
}

// models.conf lines: vendor:model:WxH (decimal EDID ids); # comments allowed
static int loadModels(ModelEntry *out, int max) {
    NSString *path = [baseDir() stringByAppendingPathComponent:@"models.conf"];
    FILE *f = fopen(path.UTF8String, "r");
    int n = 0;
    if (f) {
        char line[256];
        while (n < max && fgets(line, sizeof(line), f)) {
            ModelEntry e;
            if (line[0] == '#') continue;
            if (sscanf(line, "%u:%u:%ux%u", &e.vendor, &e.model, &e.pw, &e.ph) == 4)
                out[n++] = e;
        }
        fclose(f);
    }
    if (n == 0) out[n++] = (ModelEntry){4268, 41413, 1920, 1080}; // DELL P2422H
    return n;
}

static NSString *uuidString(CGDirectDisplayID did) {
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(did);
    if (!u) return nil;
    NSString *s = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, u);
    CFRelease(u);
    return s;
}

int main(int argc, char **argv) {
    BOOL wantVirtual = (argc > 1 && strcmp(argv[1], "-virtual") == 0);

    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);

    if (wantVirtual) {
        NSMutableArray *found = [NSMutableArray array];
        for (uint32_t i = 0; i < count; i++) {
            if (CGDisplayVendorNumber(ids[i]) != kVirtVendor) continue;
            if (CGDisplayModelNumber(ids[i]) != kVirtModel) continue;
            NSString *s = uuidString(ids[i]);
            if (s) [found addObject:@{@"serial": @(CGDisplaySerialNumber(ids[i])),
                                      @"uuid": s}];
        }
        // Stable order: serial 1 = first virtual, 2 = second
        [found sortUsingDescriptors:
            @[[NSSortDescriptor sortDescriptorWithKey:@"serial" ascending:YES]]];
        for (NSDictionary *d in found) printf("%s\n", [d[@"uuid"] UTF8String]);
        return 0;
    }

    ModelEntry models[32];
    int nModels = loadModels(models, 32);
    for (uint32_t i = 0; i < count; i++) {
        for (int m = 0; m < nModels; m++) {
            if (CGDisplayVendorNumber(ids[i]) != models[m].vendor) continue;
            if (CGDisplayModelNumber(ids[i]) != models[m].model) continue;
            NSString *s = uuidString(ids[i]);
            if (s) printf("%s %ux%u\n", [s UTF8String], models[m].pw, models[m].ph);
            break;
        }
    }
    return 0;
}
