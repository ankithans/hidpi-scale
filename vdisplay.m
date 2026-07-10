// vdisplay.m — creates headless HiDPI virtual displays and auto-applies
// scaling when a monitor listed in models.conf is (dis)connected.
// Mirror a physical monitor to a virtual display to get "looks like"
// resolutions beyond the panel's native mode (the old BetterDummy trick).
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics -o vdisplay vdisplay.m
// Run:   ./vdisplay   (keeps running; the displays exist while the process lives)

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach-o/dyld.h>

// Private CoreGraphics classes (same API used by BetterDummy/DeskPad/FluffyDisplay)
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

typedef struct { uint32_t vendor, model, pw, ph; } ModelEntry;

// Scale steps offered per panel: native, ~7%, 20%, 33% more space.
// Integer math here must match set-scale.sh exactly so modes line up.
static const unsigned kFactors[][2] = {{1, 1}, {16, 15}, {6, 5}, {4, 3}};
static const int kNumFactors = 4;

// Directory this binary lives in — scripts, conf, and logs sit next to it
static NSString *baseDir(void) {
    static NSString *dir = nil;
    if (!dir) {
        char exe[PATH_MAX];
        uint32_t sz = sizeof(exe);
        _NSGetExecutablePath(exe, &sz);
        char real[PATH_MAX];
        realpath(exe, real);
        dir = [[NSString stringWithUTF8String:real] stringByDeletingLastPathComponent];
    }
    return dir;
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

// Set of currently online displayIDs matching models.conf (never our virtuals)
static NSSet *monitoredSet(void) {
    ModelEntry models[32];
    int nModels = loadModels(models, 32);
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    NSMutableSet *set = [NSMutableSet set];
    for (uint32_t i = 0; i < count; i++) {
        for (int m = 0; m < nModels; m++) {
            if (CGDisplayVendorNumber(ids[i]) == models[m].vendor &&
                CGDisplayModelNumber(ids[i]) == models[m].model) {
                [set addObject:@(ids[i])];
                break;
            }
        }
    }
    return set;
}

static NSSet *lastApplied = nil;
static dispatch_block_t pendingApply = nil;
static void ensureVirtualCount(NSUInteger want);

static void applyIfMonitorSetChanged(void) {
    NSSet *now = monitoredSet();
    if ([now isEqualToSet:lastApplied]) return;
    lastApplied = now;
    printf("monitored set changed (%lu connected)\n", (unsigned long)now.count);
    ensureVirtualCount(MIN(now.count, (NSUInteger)2));
    fflush(stdout);
    if (now.count == 0) return;
    // sleep lets the just-created virtual displays finish registering
    NSString *cmd = [NSString stringWithFormat:
        @"{ sleep 2; '%@/set-scale.sh'; } >> '%@/autoscale.log' 2>&1 &",
        baseDir(), baseDir()];
    system(cmd.UTF8String);
}

static void reconfigCallback(CGDirectDisplayID display,
                             CGDisplayChangeSummaryFlags flags,
                             void *userInfo) {
    if (!(flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag))) return;
    // Debounce: hotplug fires a burst of callbacks; act 3s after the last one
    if (pendingApply) dispatch_block_cancel(pendingApply);
    pendingApply = dispatch_block_create(0, ^{ applyIfMonitorSetChanged(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), pendingApply);
}

// One "looks like" mode per scale step per panel in models.conf, deduped
static NSArray *buildModes(unsigned *maxW, unsigned *maxH) {
    ModelEntry models[32];
    int nModels = loadModels(models, 32);
    NSMutableArray *modes = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    *maxW = 0; *maxH = 0;
    for (int m = 0; m < nModels; m++) {
        for (int fi = 0; fi < kNumFactors; fi++) {
            unsigned n = kFactors[fi][0], d = kFactors[fi][1];
            unsigned w = (models[m].pw * n + d / 2) / d; w -= w % 2;
            unsigned h = (models[m].ph * n + d / 2) / d; h -= h % 2;
            NSNumber *key = @(((uint64_t)w << 32) | h);
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:w
                                                                  height:h
                                                             refreshRate:60]];
            if (w > *maxW) *maxW = w;
            if (h > *maxH) *maxH = h;
        }
    }
    return modes;
}

static NSMutableArray *displays = nil;
static CGVirtualDisplay *makeDisplay(NSString *name, unsigned int serial,
                                     NSArray *modes, unsigned maxW, unsigned maxH);
static NSArray *buildModes(unsigned *maxW, unsigned *maxH);

// Keep exactly `want` virtual displays alive. Releasing a CGVirtualDisplay
// destroys it, so virtuals exist only while matched monitors are connected.
static void ensureVirtualCount(NSUInteger want) {
    while (displays.count > want) {
        [displays removeLastObject];
        printf("virtual display %lu removed\n", (unsigned long)displays.count + 1);
    }
    if (displays.count >= want) return;
    unsigned maxW, maxH;
    NSArray *modes = buildModes(&maxW, &maxH);
    NSArray *names = @[ @"HiDPI Scale", @"HiDPI Scale 2" ];
    while (displays.count < want) {
        NSUInteger i = displays.count;
        CGVirtualDisplay *d = makeDisplay(names[i], (unsigned int)i + 1,
                                          modes, maxW, maxH);
        if (!d) {
            fprintf(stderr, "Failed to create virtual display %s\n",
                    [names[i] UTF8String]);
            return;
        }
        [displays addObject:d];
        printf("Virtual display \"%s\" up, displayID=%u\n",
               [names[i] UTF8String], d.displayID);
    }
}

static CGVirtualDisplay *makeDisplay(NSString *name, unsigned int serial,
                                     NSArray *modes, unsigned maxW, unsigned maxH) {
    CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
    desc.name = name;
    desc.maxPixelsWide = maxW * 2;   // HiDPI backing is 2x the largest mode
    desc.maxPixelsHigh = maxH * 2;
    // Physical size of a ~24" panel so DPI/menu sizing stays sane
    desc.sizeInMillimeters = CGSizeMake(527, 296);
    desc.productID = 0xD311; // arbitrary; must match lsmon.m
    desc.vendorID = 0xF0F0;
    desc.serialNum = serial;
    desc.queue = dispatch_get_main_queue();

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display) return nil;

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = 1;
    settings.modes = modes;
    if (![display applySettings:settings]) return nil;
    return display;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        displays = [NSMutableArray array];
        printf("hidpi-scale daemon started (virtual displays created on demand)\n");
        fflush(stdout);

        // Create/destroy virtuals and apply scaling on monitor (dis)connect
        CGDisplayRegisterReconfigurationCallback(reconfigCallback, NULL);
        // Initial check shortly after login/startup, once displays settle
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(),
                       ^{ applyIfMonitorSetChanged(); });

        dispatch_main();
    }
    return 0;
}
