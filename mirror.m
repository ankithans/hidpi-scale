// mirror.m — explicitly mirror one display onto another (or unmirror).
// Usage: mirror <display-uuid> <master-uuid>   mirror display onto master
//        mirror <display-uuid> off             make display standalone
//
// Build: clang -framework Foundation -framework CoreGraphics -o mirror mirror.m

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Exported by CoreGraphics but not declared in public headers
CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t displayID);

static CGDirectDisplayID findDisplay(NSString *uuidWanted) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) {
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if (!u) continue;
        NSString *s = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, u);
        CFRelease(u);
        if ([s caseInsensitiveCompare:uuidWanted] == NSOrderedSame) return ids[i];
    }
    return kCGNullDirectDisplay;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <display-uuid> <master-uuid|off>\n", argv[0]);
            return 1;
        }
        CGDirectDisplayID slave = findDisplay(@(argv[1]));
        if (slave == kCGNullDirectDisplay) {
            fprintf(stderr, "display %s not found\n", argv[1]);
            return 1;
        }
        CGDirectDisplayID master = kCGNullDirectDisplay;
        if (strcmp(argv[2], "off") != 0) {
            master = findDisplay(@(argv[2]));
            if (master == kCGNullDirectDisplay) {
                fprintf(stderr, "master %s not found\n", argv[2]);
                return 1;
            }
        }
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) {
            fprintf(stderr, "CGBeginDisplayConfiguration failed\n");
            return 1;
        }
        if (CGConfigureDisplayMirrorOfDisplay(cfg, slave, master) != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(cfg);
            fprintf(stderr, "CGConfigureDisplayMirrorOfDisplay failed\n");
            return 1;
        }
        if (CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently) != kCGErrorSuccess) {
            fprintf(stderr, "CGCompleteDisplayConfiguration failed\n");
            return 1;
        }
        printf("ok\n");
        return 0;
    }
}
