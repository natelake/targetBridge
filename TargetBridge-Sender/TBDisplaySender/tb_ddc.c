// tb_ddc.c — minimal DDC/CI luminance control for the external display on
// Apple Silicon, over the IOAVService I2C interface (HDMI or DP).
//
// Deliberately avoids display enumeration: IOAVServiceCreate() returns the
// AVService of the default (first) external display, which is exactly the
// single hardware monitor in this setup. Enumerating IORegistry display paths
// crashes some tools (m1ddc) when TargetBridge's virtual displays exist.
//
// Protocol: DDC/CI over I2C chip address 0x37, register 0x51. Write is a
// "Set VCP Feature" (0x03); read is "Get VCP Feature" (0x01) whose 12-byte
// reply carries opcode 0x02 at [2], result code at [3], the echoed VCP code
// at [4], max at [6..7] and current at [8..9], big-endian. Panels report
// their own range (a Samsung G50F says max=50), so all public values are
// percentages of the panel's max. Symbols are resolved via dlsym so the
// build needs no private framework stubs.

#include "tb_ddc.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

#define DDC_CHIP 0x37
#define DDC_REG 0x51
#define VCP_LUMINANCE 0x10
#define DDC_WAIT_US 20000
#define DDC_READ_WAIT_US 40000
#define DDC_WRITE_ITERATIONS 2

typedef CFTypeRef TBAVServiceRef;
typedef TBAVServiceRef (*TBAVCreateF)(CFAllocatorRef);
typedef int (*TBAVReadF)(TBAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef int (*TBAVWriteF)(TBAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static TBAVCreateF av_create;
static TBAVReadF av_read;
static TBAVWriteF av_write;
static TBAVServiceRef av_service;
static int cached_max;   // panel's luminance range, learned from the first read

static int tb_ddc_init(void) {
    if (av_service) return 0;
    if (!av_create) {
        av_create = (TBAVCreateF)dlsym(RTLD_DEFAULT, "IOAVServiceCreate");
        if (!av_create) {
            void *lib = dlopen(
                "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
                RTLD_LAZY);
            if (lib) av_create = (TBAVCreateF)dlsym(lib, "IOAVServiceCreate");
        }
        av_read = (TBAVReadF)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        av_write = (TBAVWriteF)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    }
    if (!av_create || !av_write || !av_read) return -1;
    av_service = av_create(kCFAllocatorDefault);
    return av_service ? 0 : -1;
}

int tb_ddc_available(void) {
    return tb_ddc_init() == 0;
}

static int tb_ddc_read_raw(int *current, int *max) {
    uint8_t req[4];
    req[0] = 0x82;                // source address | length marker
    req[1] = 0x01;                // Get VCP Feature
    req[2] = VCP_LUMINANCE;
    req[3] = 0x6E ^ DDC_REG ^ req[0] ^ req[1] ^ req[2];

    usleep(DDC_WAIT_US);
    if (av_write(av_service, DDC_CHIP, DDC_REG, req, sizeof(req)) != 0)
        return -1;

    uint8_t reply[12];
    memset(reply, 0, sizeof(reply));
    usleep(DDC_READ_WAIT_US);
    if (av_read(av_service, DDC_CHIP, DDC_REG, reply, sizeof(reply)) != 0)
        return -1;

    // Verified layout on the wire: 6e 88 02 00 10 00 <max16> <cur16> <sum>
    if (reply[2] != 0x02 || reply[3] != 0x00 || reply[4] != VCP_LUMINANCE)
        return -2;
    if (max) *max = (reply[6] << 8) | reply[7];
    if (current) *current = (reply[8] << 8) | reply[9];
    return 0;
}

static int tb_ddc_ensure_max(void) {
    if (cached_max > 0) return cached_max;
    int cur = 0, max = 0;
    if (tb_ddc_read_raw(&cur, &max) == 0 && max > 0) cached_max = max;
    return cached_max > 0 ? cached_max : 100;
}

int tb_ddc_set_percent(int percent) {
    if (tb_ddc_init() != 0) return -1;
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    int max = tb_ddc_ensure_max();
    int value = (percent * max + 50) / 100;

    uint8_t d[6];
    d[0] = 0x84;                  // source address | length marker
    d[1] = 0x03;                  // Set VCP Feature
    d[2] = VCP_LUMINANCE;
    d[3] = (uint8_t)(value >> 8);
    d[4] = (uint8_t)(value & 0xFF);
    d[5] = 0x6E ^ DDC_REG ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4];

    int ret = -1;
    for (int i = 0; i < DDC_WRITE_ITERATIONS; i++) {
        usleep(DDC_WAIT_US);
        ret = av_write(av_service, DDC_CHIP, DDC_REG, d, sizeof(d));
        if (ret != 0) return ret;
    }
    return ret;
}

int tb_ddc_get_percent(void) {
    if (tb_ddc_init() != 0) return -1;
    int cur = 0, max = 0;
    int rc = tb_ddc_read_raw(&cur, &max);
    if (rc != 0) return rc;
    if (max <= 0) return -2;
    cached_max = max;
    return (cur * 100 + max / 2) / max;
}
