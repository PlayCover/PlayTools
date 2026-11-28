#import <Foundation/Foundation.h>
#include <TargetConditionals.h>

#if TARGET_OS_MACCATALYST
#include <cstring>
#include <dlfcn.h>
#include <iostream>

template <typename Stream>
static decltype(std::declval<Stream &>().rdbuf()) pt_captureSystemStreamBuffer(Stream &stream) {
    auto *systemBuffer = stream.rdbuf();
    Dl_info owner = {};
    if (!systemBuffer || !dladdr(systemBuffer, &owner) || !owner.dli_fname ||
        std::strcmp(owner.dli_fname, "/usr/lib/libc++.1.dylib") != 0) {
        return nullptr;
    }
    return systemBuffer;
}

template <typename Stream, typename Buffer>
static void pt_restoreSystemStreamBuffer(Stream &stream, Buffer *systemBuffer) {
    if (!systemBuffer) {
        return;
    }
    auto *appBuffer = stream.rdbuf();
    if (appBuffer && appBuffer != systemBuffer) {
        Dl_info vtableOwner = {};
        void *vtable = *reinterpret_cast<void * const *>(appBuffer);
        if (vtable && dladdr(vtable, &vtableOwner)) {
            try {
                stream.flush();
            } catch (...) {
                // Restore the system buffer even if flushing the app buffer failed.
            }
        }
        stream.rdbuf(systemBuffer);
    }
}

__attribute__((constructor))
static void pt_installStandardStreamTerminationGuard(void) {
    @autoreleasepool {
        // Apps that install custom C++ streambufs may tear them down before libc++ DoIOSInit::~DoIOSInit flushes streams at exit.
        std::streambuf *coutBuf = pt_captureSystemStreamBuffer(std::cout);
        std::streambuf *clogBuf = pt_captureSystemStreamBuffer(std::clog);
        std::streambuf *cerrBuf = pt_captureSystemStreamBuffer(std::cerr);
        std::wstreambuf *wcoutBuf = pt_captureSystemStreamBuffer(std::wcout);
        std::wstreambuf *wclogBuf = pt_captureSystemStreamBuffer(std::wclog);
        std::wstreambuf *wcerrBuf = pt_captureSystemStreamBuffer(std::wcerr);
        if (!coutBuf && !clogBuf && !cerrBuf && !wcoutBuf && !wclogBuf && !wcerrBuf) {
            return;
        }

        [NSNotificationCenter.defaultCenter addObserverForName:@"NSApplicationWillTerminateNotification"
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *notification) {
            pt_restoreSystemStreamBuffer(std::cout, coutBuf);
            pt_restoreSystemStreamBuffer(std::clog, clogBuf);
            pt_restoreSystemStreamBuffer(std::cerr, cerrBuf);
            pt_restoreSystemStreamBuffer(std::wcout, wcoutBuf);
            pt_restoreSystemStreamBuffer(std::wclog, wclogBuf);
            pt_restoreSystemStreamBuffer(std::wcerr, wcerrBuf);
        }];
    }
}
#endif
