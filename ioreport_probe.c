// ioreport_probe.c — does Apple SoC power/energy telemetry surface here?
//
// mactop / asitop / macmon read CPU/GPU/ANE power and DRAM bandwidth through
// the private IOReport API. Its first step is IOReportCopyChannelsInGroup
// for the "Energy Model" group. On bare-metal Apple Silicon this returns many
// channels; inside an Apple Virtualization.framework guest the SoC PMGR /
// memory-controller IOKit nodes are not passed through, so the group is empty
// and mactop reads nothing.
//
// This probe loads libIOReport at runtime (dlopen/dlsym so we don't link a
// private framework), counts the channels in the relevant groups, and — when
// channels exist — subscribes and prints one live sample delta.
//
// Exit code: 0 = Energy Model channels present (telemetry available)
//            1 = no Energy Model channels (telemetry unavailable / virtualized)
//            2 = could not load IOReport at all
//
// Build:  clang -O2 -fblocks ioreport_probe.c -framework CoreFoundation -o ioreport_probe

#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

typedef CFDictionaryRef (*CopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void *IOReportSubscriptionRef;
typedef IOReportSubscriptionRef (*CreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef void (*Iterate)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef CFStringRef (*ChanGetStr)(CFDictionaryRef);
typedef int64_t (*SimpleGetInt)(CFDictionaryRef, int);

static const char *cfstr(CFStringRef s, char *buf, int n) {
    buf[0] = '\0';
    if (s) CFStringGetCString(s, buf, n, kCFStringEncodingUTF8);
    return buf;
}

// Returns channel count for a group, or -1 if the group dict was NULL.
static int count_group(CopyChannelsInGroup f, const char *group) {
    CFStringRef g = CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8);
    CFDictionaryRef ch = f(g, NULL, 0, 0, 0);
    int n = -1;
    if (ch) {
        CFArrayRef arr = (CFArrayRef)CFDictionaryGetValue(ch, CFSTR("IOReportChannels"));
        n = arr ? (int)CFArrayGetCount(arr) : 0;
        CFRelease(ch);
    }
    CFRelease(g);
    return n;
}

int main(void) {
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!h) h = dlopen("libIOReport.dylib", RTLD_NOW);
    if (!h) {
        printf("FAIL: cannot dlopen libIOReport: %s\n", dlerror());
        return 2;
    }

    CopyChannelsInGroup copy_group = (CopyChannelsInGroup)dlsym(h, "IOReportCopyChannelsInGroup");
    if (!copy_group) {
        printf("FAIL: missing symbol IOReportCopyChannelsInGroup\n");
        return 2;
    }

    const char *groups[] = {"Energy Model", "CPU Stats", "GPU Stats", "PMP", "AMC Stats"};
    int energy = -1;
    printf("=== IOReport channel groups ===\n");
    for (int i = 0; i < (int)(sizeof(groups) / sizeof(groups[0])); i++) {
        int n = count_group(copy_group, groups[i]);
        printf("  %-14s : %d channels\n", groups[i], n);
        if (i == 0) energy = n;
    }

    // Best-effort: subscribe to Energy Model and print one sample delta.
    // Only attempted when channels exist, so a virtualized guest never reaches
    // the subscription path (and cannot crash there).
    CreateSubscription create_sub = (CreateSubscription)dlsym(h, "IOReportCreateSubscription");
    CreateSamples create_samples = (CreateSamples)dlsym(h, "IOReportCreateSamples");
    CreateSamplesDelta create_delta = (CreateSamplesDelta)dlsym(h, "IOReportCreateSamplesDelta");
    Iterate iterate = (Iterate)dlsym(h, "IOReportIterate");
    ChanGetStr chan_group = (ChanGetStr)dlsym(h, "IOReportChannelGetGroup");
    ChanGetStr chan_name = (ChanGetStr)dlsym(h, "IOReportChannelGetChannelName");
    SimpleGetInt simple_int = (SimpleGetInt)dlsym(h, "IOReportSimpleGetIntegerValue");

    if (energy > 0 && create_sub && create_samples && create_delta && iterate) {
        CFStringRef g = CFStringCreateWithCString(NULL, "Energy Model", kCFStringEncodingUTF8);
        CFDictionaryRef ch = copy_group(g, NULL, 0, 0, 0);
        if (ch) {
            CFMutableDictionaryRef mch = CFDictionaryCreateMutableCopy(NULL, 0, ch);
            CFMutableDictionaryRef subbed = NULL;
            IOReportSubscriptionRef sub = create_sub(NULL, mch, &subbed, 0, NULL);
            if (sub && subbed) {
                CFDictionaryRef s1 = create_samples(sub, subbed, NULL);
                usleep(500000);
                CFDictionaryRef s2 = create_samples(sub, subbed, NULL);
                CFDictionaryRef delta = create_delta(s1, s2, NULL);
                printf("\n=== Energy Model — one 500ms sample delta ===\n");
                __block int rows = 0;
                iterate(delta, ^int(CFDictionaryRef c) {
                    char gb[128], nb[128];
                    long long v = simple_int ? (long long)simple_int(c, 0) : -1;
                    printf("  [%s] %s = %lld\n",
                           chan_group ? cfstr(chan_group(c), gb, sizeof(gb)) : "?",
                           chan_name ? cfstr(chan_name(c), nb, sizeof(nb)) : "?",
                           v);
                    rows++;
                    return 0; // kIOReportIterOk — continue
                });
                if (rows == 0) printf("  (delta had no rows)\n");
                if (s1) CFRelease(s1);
                if (s2) CFRelease(s2);
                if (delta) CFRelease(delta);
            } else {
                printf("\n(subscription failed; cannot sample)\n");
            }
            if (mch) CFRelease(mch);
            CFRelease(ch);
        }
        CFRelease(g);
    } else {
        printf("\n(sampling skipped: no Energy Model channels or missing symbols)\n");
    }

    printf("\n============================================================\n");
    if (energy > 0) {
        printf("VERDICT: 'Energy Model' has %d channels -> SoC power/energy telemetry AVAILABLE.\n", energy);
        printf("         mactop / asitop / macmon (and DRAM-bandwidth reads) work here.\n");
        return 0;
    }
    printf("VERDICT: 'Energy Model' has %d channels -> SoC power/energy telemetry UNAVAILABLE.\n", energy);
    printf("         mactop power + DRAM-bandwidth reads are empty here.\n");
    printf("         Consistent with an Apple Virtualization.framework guest (no SoC passthrough).\n");
    return 1;
}
