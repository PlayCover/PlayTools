//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#if TARGET_OS_MACCATALYST
#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/fixup-chains.h>
#import <mach/mach.h>
#import <os/lock.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#endif

@import MachO;

#ifndef PLATFORM_IOS
#define PLATFORM_IOS 2
#endif
#ifndef PLATFORM_MACCATALYST
#define PLATFORM_MACCATALYST 6
#endif

typedef struct {
    uint32_t platform;
    uint32_t version;
} pt_build_version_t;

extern uint32_t dyld_get_active_platform(void);
extern bool _availability_version_check(uint32_t count, const pt_build_version_t versions[]);

#define PT_INTERPOSE_EXPORT __attribute__((visibility("default"), used))

typedef uint32_t (*pt_active_platform_fn)(void);
typedef bool (*pt_availability_version_check_fn)(uint32_t, const pt_build_version_t []);
PT_INTERPOSE_EXPORT int pt_dyld_get_active_platform(void);
PT_INTERPOSE_EXPORT bool pt_availability_version_check(uint32_t count, const pt_build_version_t versions[]);
DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_availability_version_check, _availability_version_check)

typedef struct {
    uint32_t minVersion;
    const char *frameworkPath;
    size_t frameworkPathLen;
    const char *iosSupportPath;
    const char *probeSymbol;
    const char *compatSubpath;
    atomic_bool checked;
    atomic_bool loaded;
} pt_weak_ios_framework_t;

#define PT_WEAK_IOS_FRAMEWORK_ENTRY(ver, pathStr, symStr, compatStr) \
    { (ver), (pathStr), sizeof(pathStr), "/System/iOSSupport" pathStr, (symStr), (compatStr), ATOMIC_VAR_INIT(false), ATOMIC_VAR_INIT(false) }

static pt_weak_ios_framework_t pt_weak_ios_frameworks[] = {
    // WirelessInsights.ServicePredictionProvider was introduced in iOS 26.0 (@available(macCatalyst, unavailable)).
    // On Mac Catalyst hosts that omit WirelessInsights.framework, PlayTools bundles a library-evolution
    // compatibility framework and rebinds NULL weak-import GOT slots so @available(iOS 26.0, *) stays
    // monotonic with @available(iOS 27.1, *) and never breaks unrelated iOS 26 UIKit callers.
    PT_WEAK_IOS_FRAMEWORK_ENTRY(0x001a0000,
                                "/System/Library/Frameworks/WirelessInsights.framework/WirelessInsights",
                                "$s16WirelessInsights25ServicePredictionProviderCMn",
                                "WirelessInsightsCompatibility/WirelessInsights.framework/WirelessInsights"),
};

static uint32_t pt_find_weak_dylib_ordinal(const struct mach_header_64 *header,
                                           const char *frameworkPath,
                                           size_t pathLen) {
    if (!header || header->magic != MH_MAGIC_64 || !frameworkPath || pathLen == 0) {
        return 0;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    size_t remaining = header->sizeofcmds;
    uint32_t dylibOrdinal = 0;
    for (uint32_t i = 0; i < header->ncmds && remaining >= sizeof(struct load_command); i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining || command->cmdsize % 8 != 0) {
            return 0;
        }
        if (command->cmd == LC_LOAD_DYLIB ||
            command->cmd == LC_LOAD_WEAK_DYLIB ||
            command->cmd == LC_REEXPORT_DYLIB ||
            command->cmd == LC_LOAD_UPWARD_DYLIB ||
            command->cmd == LC_LAZY_LOAD_DYLIB) {
            dylibOrdinal++;
            if (command->cmd == LC_LOAD_WEAK_DYLIB && command->cmdsize >= sizeof(struct dylib_command)) {
                const struct dylib_command *dylib = (const struct dylib_command *)command;
                uint32_t offset = dylib->dylib.name.offset;
                if (offset >= sizeof(*dylib) && offset <= command->cmdsize
                    && command->cmdsize - offset >= pathLen
                    && memcmp(cursor + offset, frameworkPath, pathLen) == 0) {
                    return dylibOrdinal;
                }
            }
        }
        remaining -= command->cmdsize;
        cursor += command->cmdsize;
    }
    return 0;
}

static bool pt_caller_weak_links_framework(const void *caller, const char *frameworkPath, size_t pathLen) {
    Dl_info info;
    if (!caller || !dladdr(caller, &info) || !info.dli_fbase) {
        return false;
    }
    return pt_find_weak_dylib_ordinal((const struct mach_header_64 *)info.dli_fbase, frameworkPath, pathLen) > 0;
}

#if TARGET_OS_MACCATALYST
typedef struct {
    uintptr_t slotAddr;
    void *value;
    vm_prot_t restoreProt;
} pt_got_patch_t;

static bool pt_locate_compat_framework_path(const char *compatSubpath, char *outPath, size_t outSize) {
    if (!compatSubpath || !outPath || outSize == 0) {
        return false;
    }
    Dl_info info;
    if (!dladdr((const void *)pt_locate_compat_framework_path, &info) || !info.dli_fname) {
        return false;
    }
    const char *slash = strrchr(info.dli_fname, '/');
    if (!slash) {
        return false;
    }
    size_t dirLen = (size_t)(slash - info.dli_fname);
    if (dirLen == 0 || dirLen >= PATH_MAX) {
        return false;
    }
    int n = snprintf(outPath, outSize, "%.*s/Resources/%s", (int)dirLen, info.dli_fname, compatSubpath);
    if (n > 0 && (size_t)n < outSize && access(outPath, R_OK) == 0) {
        return true;
    }
    return false;
}

static bool pt_find_arm64_macho_slice(const uint8_t *fileBase,
                                      size_t fileSize,
                                      const uint8_t **outSliceBase,
                                      size_t *outSliceSize) {
    if (!fileBase || fileSize < sizeof(struct mach_header_64)) {
        return false;
    }
    uint32_t magic = *(const uint32_t *)fileBase;
    if (magic == MH_MAGIC_64) {
        *outSliceBase = fileBase;
        *outSliceSize = fileSize;
        return true;
    }
    if ((magic == FAT_MAGIC || magic == FAT_CIGAM) && fileSize >= sizeof(struct fat_header)) {
        const struct fat_header *fh = (const struct fat_header *)fileBase;
        uint32_t narch = (magic == FAT_CIGAM) ? OSSwapBigToHostInt32(fh->nfat_arch) : fh->nfat_arch;
        if (narch > 32 || sizeof(struct fat_header) + (size_t)narch * sizeof(struct fat_arch) > fileSize) {
            return false;
        }
        const struct fat_arch *archs = (const struct fat_arch *)(fh + 1);
        for (uint32_t i = 0; i < narch; i++) {
            cpu_type_t cpu = (magic == FAT_CIGAM) ? (cpu_type_t)OSSwapBigToHostInt32((uint32_t)archs[i].cputype) : archs[i].cputype;
            uint32_t off = (magic == FAT_CIGAM) ? OSSwapBigToHostInt32(archs[i].offset) : archs[i].offset;
            uint32_t sz = (magic == FAT_CIGAM) ? OSSwapBigToHostInt32(archs[i].size) : archs[i].size;
            if (cpu == CPU_TYPE_ARM64 && (uint64_t)off + (uint64_t)sz <= fileSize && sz >= sizeof(struct mach_header_64)) {
                *outSliceBase = fileBase + off;
                *outSliceSize = sz;
                return true;
            }
        }
        return false;
    }
    if ((magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) && fileSize >= sizeof(struct fat_header)) {
        const struct fat_header *fh = (const struct fat_header *)fileBase;
        uint32_t narch = (magic == FAT_CIGAM_64) ? OSSwapBigToHostInt32(fh->nfat_arch) : fh->nfat_arch;
        if (narch > 32 || sizeof(struct fat_header) + (size_t)narch * sizeof(struct fat_arch_64) > fileSize) {
            return false;
        }
        const struct fat_arch_64 *archs = (const struct fat_arch_64 *)(fh + 1);
        for (uint32_t i = 0; i < narch; i++) {
            cpu_type_t cpu = (magic == FAT_CIGAM_64) ? (cpu_type_t)OSSwapBigToHostInt32((uint32_t)archs[i].cputype) : archs[i].cputype;
            uint64_t off = (magic == FAT_CIGAM_64) ? OSSwapBigToHostInt64(archs[i].offset) : archs[i].offset;
            uint64_t sz = (magic == FAT_CIGAM_64) ? OSSwapBigToHostInt64(archs[i].size) : archs[i].size;
            if (cpu == CPU_TYPE_ARM64 && off <= fileSize && sz <= fileSize - off && sz >= sizeof(struct mach_header_64)) {
                *outSliceBase = fileBase + off;
                *outSliceSize = (size_t)sz;
                return true;
            }
        }
        return false;
    }
    return false;
}

static bool pt_decode_chained_bind_entry(const uint8_t *ptr,
                                         uint16_t pointerFormat,
                                         bool *outIsBind,
                                         uint32_t *outOrdinal,
                                         int64_t *outAddend,
                                         uint32_t *outNextBytes) {
    switch (pointerFormat) {
        case DYLD_CHAINED_PTR_64:
        case DYLD_CHAINED_PTR_64_OFFSET: {
            const struct dyld_chained_ptr_64_bind *b = (const struct dyld_chained_ptr_64_bind *)ptr;
            *outIsBind = (b->bind != 0);
            *outOrdinal = (uint32_t)b->ordinal;
            *outAddend = (int64_t)b->addend;
            *outNextBytes = (uint32_t)b->next * 4u;
            return true;
        }
        case DYLD_CHAINED_PTR_ARM64E:
        case DYLD_CHAINED_PTR_ARM64E_USERLAND: {
            const struct dyld_chained_ptr_arm64e_bind *b = (const struct dyld_chained_ptr_arm64e_bind *)ptr;
            *outIsBind = (b->bind != 0);
            *outOrdinal = (uint32_t)b->ordinal;
            if (b->auth) {
                *outAddend = 0;
            } else {
                int64_t a = (int64_t)b->addend;
                if (a & (1LL << 18)) {
                    a |= ~((1LL << 19) - 1);
                }
                *outAddend = a;
            }
            *outNextBytes = (uint32_t)b->next * 8u;
            return true;
        }
        case DYLD_CHAINED_PTR_ARM64E_USERLAND24: {
            const struct dyld_chained_ptr_arm64e_bind24 *b = (const struct dyld_chained_ptr_arm64e_bind24 *)ptr;
            *outIsBind = (b->bind != 0);
            *outOrdinal = (uint32_t)b->ordinal;
            if (b->auth) {
                *outAddend = 0;
            } else {
                int64_t a = (int64_t)b->addend;
                if (a & (1LL << 18)) {
                    a |= ~((1LL << 19) - 1);
                }
                *outAddend = a;
            }
            *outNextBytes = (uint32_t)b->next * 8u;
            return true;
        }
        default:
            return false;
    }
}

static bool pt_rebind_weak_chained_fixups_in_image(const struct mach_header_64 *liveHeader,
                                                   intptr_t slide,
                                                   const char *imagePath,
                                                   uint32_t targetOrdinal,
                                                   void *compatHandle) {
    if (!liveHeader || !imagePath || targetOrdinal == 0 || !compatHandle) {
        return false;
    }
    int fd = open(imagePath, O_RDONLY);
    if (fd < 0) {
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return false;
    }
    size_t fileSize = (size_t)st.st_size;
    void *mapped = mmap(NULL, fileSize, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        return false;
    }

    bool success = false;
    void **resolvedImports = NULL;
    int64_t *importAddends = NULL;
    pt_got_patch_t *patches = NULL;
    size_t patchCount = 0;
    size_t patchCap = 0;

    const uint8_t *sliceBase = NULL;
    size_t sliceSize = 0;
    if (!pt_find_arm64_macho_slice((const uint8_t *)mapped, fileSize, &sliceBase, &sliceSize)) {
        goto cleanup;
    }

    const struct mach_header_64 *diskHdr = (const struct mach_header_64 *)sliceBase;
    if (diskHdr->magic != MH_MAGIC_64 ||
        diskHdr->sizeofcmds > sliceSize - sizeof(struct mach_header_64)) {
        goto cleanup;
    }

    const struct segment_command_64 *segs[128];
    uint32_t segCount = 0;
    const struct linkedit_data_command *cfCmd = NULL;
    const uint8_t *cursor = (const uint8_t *)(diskHdr + 1);
    size_t remaining = diskHdr->sizeofcmds;
    for (uint32_t i = 0; i < diskHdr->ncmds && remaining >= sizeof(struct load_command); i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > remaining || lc->cmdsize % 8 != 0) {
            goto cleanup;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            if (segCount < 128) {
                segs[segCount++] = (const struct segment_command_64 *)lc;
            }
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
            cfCmd = (const struct linkedit_data_command *)lc;
        }
        remaining -= lc->cmdsize;
        cursor += lc->cmdsize;
    }

    if (!cfCmd || cfCmd->datasize < sizeof(struct dyld_chained_fixups_header) ||
        (uint64_t)cfCmd->dataoff + (uint64_t)cfCmd->datasize > sliceSize) {
        goto cleanup;
    }

    const uint8_t *cfBase = sliceBase + cfCmd->dataoff;
    size_t cfSize = cfCmd->datasize;
    const struct dyld_chained_fixups_header *cfh = (const struct dyld_chained_fixups_header *)cfBase;
    if (cfh->fixups_version != 0 || cfh->symbols_format != 0 ||
        cfh->starts_offset >= cfSize || cfh->imports_offset >= cfSize || cfh->symbols_offset >= cfSize) {
        goto cleanup;
    }
    if (cfh->imports_count == 0) {
        success = true;
        goto cleanup;
    }

    size_t importEntrySize = 0;
    if (cfh->imports_format == DYLD_CHAINED_IMPORT) {
        importEntrySize = sizeof(struct dyld_chained_import);
    } else if (cfh->imports_format == DYLD_CHAINED_IMPORT_ADDEND) {
        importEntrySize = sizeof(struct dyld_chained_import_addend);
    } else if (cfh->imports_format == DYLD_CHAINED_IMPORT_ADDEND64) {
        importEntrySize = sizeof(struct dyld_chained_import_addend64);
    } else {
        goto cleanup;
    }
    if ((uint64_t)cfh->imports_count * importEntrySize > cfSize - cfh->imports_offset) {
        goto cleanup;
    }

    resolvedImports = (void **)calloc(cfh->imports_count, sizeof(void *));
    importAddends = (int64_t *)calloc(cfh->imports_count, sizeof(int64_t));
    if (!resolvedImports || !importAddends) {
        goto cleanup;
    }

    const uint8_t *importsPtr = cfBase + cfh->imports_offset;
    const char *symsBase = (const char *)(cfBase + cfh->symbols_offset);
    size_t symsSize = cfSize - cfh->symbols_offset;
    uint32_t matchedImportCount = 0;

    for (uint32_t i = 0; i < cfh->imports_count; i++) {
        uint32_t libOrd = 0;
        uint32_t nameOff = 0;
        int64_t addend = 0;
        if (cfh->imports_format == DYLD_CHAINED_IMPORT) {
            const struct dyld_chained_import *imp = &((const struct dyld_chained_import *)importsPtr)[i];
            libOrd = (uint32_t)imp->lib_ordinal;
            nameOff = (uint32_t)imp->name_offset;
        } else if (cfh->imports_format == DYLD_CHAINED_IMPORT_ADDEND) {
            const struct dyld_chained_import_addend *imp = &((const struct dyld_chained_import_addend *)importsPtr)[i];
            libOrd = (uint32_t)imp->lib_ordinal;
            nameOff = (uint32_t)imp->name_offset;
            addend = (int64_t)imp->addend;
        } else {
            const struct dyld_chained_import_addend64 *imp = &((const struct dyld_chained_import_addend64 *)importsPtr)[i];
            libOrd = (uint32_t)imp->lib_ordinal;
            nameOff = (uint32_t)imp->name_offset;
            addend = (int64_t)imp->addend;
        }
        if (libOrd != targetOrdinal) {
            continue;
        }
        if (nameOff >= symsSize) {
            goto cleanup;
        }
        const char *symName = symsBase + nameOff;
        if (!memchr(symName, '\0', symsSize - nameOff)) {
            goto cleanup;
        }
        const char *lookupName = (symName[0] == '_') ? (symName + 1) : symName;
        void *resolved = dlsym(compatHandle, lookupName);
        if (!resolved) {
            goto cleanup;
        }
        resolvedImports[i] = resolved;
        importAddends[i] = addend;
        matchedImportCount++;
    }

    if (matchedImportCount == 0) {
        success = true;
        goto cleanup;
    }

    const struct dyld_chained_starts_in_image *starts =
        (const struct dyld_chained_starts_in_image *)(cfBase + cfh->starts_offset);
    if (cfSize - cfh->starts_offset < sizeof(uint32_t) ||
        starts->seg_count > segCount ||
        (uint64_t)starts->seg_count * sizeof(uint32_t) > cfSize - cfh->starts_offset - sizeof(uint32_t)) {
        goto cleanup;
    }

    for (uint32_t s = 0; s < starts->seg_count; s++) {
        uint32_t segInfoOff = starts->seg_info_offset[s];
        if (segInfoOff == 0) {
            continue;
        }
        if (segInfoOff > cfSize - cfh->starts_offset - sizeof(struct dyld_chained_starts_in_segment)) {
            goto cleanup;
        }
        const struct dyld_chained_starts_in_segment *segInfo =
            (const struct dyld_chained_starts_in_segment *)((const uint8_t *)starts + segInfoOff);
        const struct segment_command_64 *seg = segs[s];
        uint32_t pageSize = segInfo->page_size;
        if (pageSize == 0 || (pageSize & (pageSize - 1)) != 0) {
            goto cleanup;
        }
        uint64_t segInfoMax = cfSize - cfh->starts_offset - segInfoOff;
        if (offsetof(struct dyld_chained_starts_in_segment, page_start) +
            (uint64_t)segInfo->page_count * sizeof(uint16_t) > segInfoMax) {
            goto cleanup;
        }
        bool formatSupported =
            (segInfo->pointer_format == DYLD_CHAINED_PTR_64 ||
             segInfo->pointer_format == DYLD_CHAINED_PTR_64_OFFSET ||
             segInfo->pointer_format == DYLD_CHAINED_PTR_ARM64E ||
             segInfo->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND ||
             segInfo->pointer_format == DYLD_CHAINED_PTR_ARM64E_USERLAND24);
        if (!formatSupported) {
            continue;
        }

        for (uint16_t p = 0; p < segInfo->page_count; p++) {
            uint16_t pageStart = segInfo->page_start[p];
            if (pageStart == DYLD_CHAINED_PTR_START_NONE) {
                continue;
            }
            uint64_t diskPageOff = seg->fileoff + (uint64_t)p * (uint64_t)pageSize;
            if (diskPageOff >= sliceSize) {
                continue;
            }

            uint16_t singleStart[1] = { pageStart };
            const uint16_t *startList = singleStart;
            bool multiStart = (pageStart & DYLD_CHAINED_PTR_START_MULTI) != 0;
            uint32_t multiIdx = 0;
            if (multiStart) {
                uint32_t overflowIdx = (uint32_t)(pageStart & ~DYLD_CHAINED_PTR_START_MULTI);
                if (offsetof(struct dyld_chained_starts_in_segment, page_start) +
                    ((uint64_t)overflowIdx + 1) * sizeof(uint16_t) > segInfoMax) {
                    goto cleanup;
                }
                startList = &segInfo->page_start[overflowIdx];
            }

            for (;;) {
                uint16_t rawStart = multiStart ? startList[multiIdx] : startList[0];
                uint32_t off = (uint32_t)(rawStart & ~DYLD_CHAINED_PTR_START_LAST);
                uint32_t maxSteps = pageSize / 4u + 1u;
                for (uint32_t step = 0; step < maxSteps; step++) {
                    if (off + sizeof(uint64_t) > pageSize || diskPageOff + off + sizeof(uint64_t) > sliceSize) {
                        break;
                    }
                    bool isBind = false;
                    uint32_t ordinal = 0;
                    int64_t ptrAddend = 0;
                    uint32_t nextBytes = 0;
                    if (!pt_decode_chained_bind_entry(sliceBase + diskPageOff + off,
                                                      segInfo->pointer_format,
                                                      &isBind,
                                                      &ordinal,
                                                      &ptrAddend,
                                                      &nextBytes)) {
                        break;
                    }
                    if (isBind && ordinal < cfh->imports_count && resolvedImports[ordinal] != NULL) {
                        uintptr_t slotAddr = (uintptr_t)seg->vmaddr + (uintptr_t)slide + (uintptr_t)p * (uintptr_t)pageSize + (uintptr_t)off;
                        if (*(void * const *)slotAddr == NULL) {
                            if (patchCount == patchCap) {
                                size_t newCap = patchCap ? (patchCap * 2) : 32;
                                pt_got_patch_t *grown = (pt_got_patch_t *)realloc(patches, newCap * sizeof(pt_got_patch_t));
                                if (!grown) {
                                    goto cleanup;
                                }
                                patches = grown;
                                patchCap = newCap;
                            }
                            int64_t totalAddend = importAddends[ordinal] + ptrAddend;
                            patches[patchCount].slotAddr = slotAddr;
                            patches[patchCount].value = (void *)((uintptr_t)resolvedImports[ordinal] + (uintptr_t)totalAddend);
                            patches[patchCount].restoreProt = (seg->initprot & (VM_PROT_READ | VM_PROT_WRITE));
                            patchCount++;
                        }
                    }
                    if (nextBytes == 0) {
                        break;
                    }
                    off += nextBytes;
                }
                if (!multiStart || (rawStart & DYLD_CHAINED_PTR_START_LAST) != 0) {
                    break;
                }
                multiIdx++;
                if (offsetof(struct dyld_chained_starts_in_segment, page_start) +
                    ((uint64_t)(pageStart & ~DYLD_CHAINED_PTR_START_MULTI) + multiIdx + 1) * sizeof(uint16_t) > segInfoMax) {
                    goto cleanup;
                }
            }
        }
    }

    size_t hostPageSize = (size_t)vm_page_size;
    for (size_t i = 0; i < patchCount; i++) {
        vm_address_t pageStart = (vm_address_t)(patches[i].slotAddr & ~(uintptr_t)(hostPageSize - 1));
        kern_return_t kr = vm_protect(mach_task_self(),
                                      pageStart,
                                      hostPageSize,
                                      FALSE,
                                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            goto cleanup;
        }
        *(void **)patches[i].slotAddr = patches[i].value;
        (void)vm_protect(mach_task_self(),
                         pageStart,
                         hostPageSize,
                         FALSE,
                         patches[i].restoreProt ? patches[i].restoreProt : VM_PROT_READ);
    }
    atomic_thread_fence(memory_order_seq_cst);
    success = true;

cleanup:
    free(patches);
    free(importAddends);
    free(resolvedImports);
    munmap(mapped, fileSize);
    return success;
}

static bool pt_try_load_and_rebind_weak_framework(pt_weak_ios_framework_t *entry) {
    if (!entry || !entry->compatSubpath) {
        return false;
    }
    if (DYLD_INTERPOSE_ORIG(pt_active_platform_fn, dyld_get_active_platform)() != PLATFORM_MACCATALYST) {
        return false;
    }

    uint32_t imageCount = _dyld_image_count();
    bool anyWeakLinked = false;
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (pt_find_weak_dylib_ordinal(hdr, entry->frameworkPath, entry->frameworkPathLen) > 0) {
            anyWeakLinked = true;
            break;
        }
    }
    if (!anyWeakLinked) {
        return false;
    }

    char compatFullPath[PATH_MAX];
    if (!pt_locate_compat_framework_path(entry->compatSubpath, compatFullPath, sizeof(compatFullPath))) {
        return false;
    }
    void *compatHandle = dlopen(compatFullPath, RTLD_NOW | RTLD_GLOBAL);
    if (!compatHandle) {
        return false;
    }

    bool allImagesRebound = true;
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        uint32_t targetOrd = pt_find_weak_dylib_ordinal(hdr, entry->frameworkPath, entry->frameworkPathLen);
        if (targetOrd == 0) {
            continue;
        }
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const char *imagePath = _dyld_get_image_name(i);
        if (!pt_rebind_weak_chained_fixups_in_image(hdr, slide, imagePath, targetOrd, compatHandle)) {
            allImagesRebound = false;
        }
    }
    return allImagesRebound;
}
#endif

static bool pt_weak_framework_loaded(pt_weak_ios_framework_t *entry) {
    if (atomic_load_explicit(&entry->checked, memory_order_acquire)) {
        return atomic_load_explicit(&entry->loaded, memory_order_relaxed);
    }
#if TARGET_OS_MACCATALYST
    static os_unfair_lock pt_weak_framework_lock = OS_UNFAIR_LOCK_INIT;
    static __thread bool pt_in_weak_framework_probe = false;
    if (pt_in_weak_framework_probe) {
        return false;
    }
    pt_in_weak_framework_probe = true;
    os_unfair_lock_lock(&pt_weak_framework_lock);
#endif
    bool isLoaded = false;
    if (atomic_load_explicit(&entry->checked, memory_order_acquire)) {
        isLoaded = atomic_load_explicit(&entry->loaded, memory_order_relaxed);
    } else {
        void *handle = dlopen(entry->frameworkPath, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) {
            handle = dlopen(entry->iosSupportPath, RTLD_LAZY | RTLD_NOLOAD);
        }
        if (handle) {
            dlclose(handle);
            isLoaded = true;
        } else if (entry->probeSymbol && dlsym(RTLD_DEFAULT, entry->probeSymbol) != NULL) {
            isLoaded = true;
        }
#if TARGET_OS_MACCATALYST
        if (!isLoaded && entry->compatSubpath != NULL) {
            isLoaded = pt_try_load_and_rebind_weak_framework(entry);
        }
#endif
        atomic_store_explicit(&entry->loaded, isLoaded, memory_order_relaxed);
        atomic_store_explicit(&entry->checked, true, memory_order_release);
    }
#if TARGET_OS_MACCATALYST
    os_unfair_lock_unlock(&pt_weak_framework_lock);
    pt_in_weak_framework_probe = false;
#endif
    return isLoaded;
}

#if TARGET_OS_MACCATALYST
static void pt_installWeakFrameworkCompatibility(void) {
    const size_t entryCount = sizeof(pt_weak_ios_frameworks) / sizeof(pt_weak_ios_frameworks[0]);
    for (size_t i = 0; i < entryCount; i++) {
        if (pt_weak_ios_frameworks[i].compatSubpath != NULL) {
            (void)pt_weak_framework_loaded(&pt_weak_ios_frameworks[i]);
        }
    }
}
#endif

PT_INTERPOSE_EXPORT bool pt_availability_version_check(uint32_t count, const pt_build_version_t versions[]) {
    // Catalyst can report newer iOS versions as available even when iOS-only weak
    // frameworks (e.g. WirelessInsights) are absent on the host.
    if (count == 1 && versions && versions[0].platform == PLATFORM_IOS
        && dyld_get_active_platform() == PLATFORM_MACCATALYST) {
        const void *caller = __builtin_return_address(0);
        const size_t entryCount = sizeof(pt_weak_ios_frameworks) / sizeof(pt_weak_ios_frameworks[0]);
        for (size_t i = 0; i < entryCount; i++) {
            pt_weak_ios_framework_t *entry = &pt_weak_ios_frameworks[i];
            if (versions[0].version == entry->minVersion
                && !pt_weak_framework_loaded(entry)
                && pt_caller_weak_links_framework(caller, entry->frameworkPath, entry->frameworkPathLen)) {
                return false;
            }
        }
    }
    return DYLD_INTERPOSE_ORIG(pt_availability_version_check_fn, _availability_version_check)(count, versions);
}

// Get device model from playcover .plist
// With a null terminator
#define DEVICE_MODEL [[[PlaySettings shared] deviceModel] cStringUsingEncoding:NSUTF8StringEncoding]
#define OEM_ID [[[PlaySettings shared] oemID] cStringUsingEncoding:NSUTF8StringEncoding]
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
PT_INTERPOSE_EXPORT int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if ([[PlaySettings shared] playChain]) {
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, O_CREAT, mod);
    }

    return open(filename, oflag);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return stat(ue_fix_filename(path), buf);
}

static int pt_access(char const* path, int mode) {
    return access(ue_fix_filename(path), mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    return rename(ue_fix_filename(old_name), ue_fix_filename(new_name));
}

static int pt_unlink(char const* path) {
    return unlink(ue_fix_filename(path));
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int pt_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[PlaySettings shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);

        BOOL exceeded_sleep_limit = NO;
        @synchronized (thread_sleep_counters) {
            int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
            int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];

            if (time == 100000) {
                int timestamp = (int)[[NSDate date] timeIntervalSince1970];
                // If it sleeps too fast, increase counter
                if (timestamp - last_sleep_attempt < 2) {
                    thread_sleep_counter++;
                } else {
                    thread_sleep_counter = 1;
                }
                last_sleep_attempt = timestamp;
                thread_sleep_counters[threadKey] = @(thread_sleep_counter);
                last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            }

            exceeded_sleep_limit = thread_sleep_counter > 100;
        }

        if (exceeded_sleep_limit) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

@implementation PlayLoader

static void __attribute__((constructor)) initialize(void) {
#if TARGET_OS_MACCATALYST
    pt_installWeakFrameworkCompatibility();
#endif
    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
