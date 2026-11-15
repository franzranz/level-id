// cusb.c – IOKit-Zugriff auf das ID14 (ohne USBDeviceOpen, wie id14probe).
#include "cusb.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

#define CUSB_DEFAULT_TIMEOUT_MS 500

struct cusb_dev {
    IOUSBDeviceInterface **dev;
};

// Matching-Dictionary fuer IOUSBHostDevice mit VID/PID (Aufrufer bekommt die Referenz).
static CFMutableDictionaryRef make_matching(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    if (!m) return NULL;
    int v = vid, p = pid;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberIntType, &p);
    if (!nv || !np) {
        if (nv) CFRelease(nv);
        if (np) CFRelease(np);
        CFRelease(m);
        return NULL;
    }
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), nv);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), np);
    CFRelease(nv);
    CFRelease(np);
    return m;
}

static cusb_dev *open_one(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef m = make_matching(vid, pid);
    if (!m) return NULL;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m); // verbraucht m
    if (!svc) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBDeviceInterface **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !dev) return NULL;

    cusb_dev *d = (cusb_dev *)calloc(1, sizeof(*d));
    if (!d) {
        (*dev)->Release(dev);
        return NULL;
    }
    d->dev = dev;
    return d;
}

cusb_dev *cusb_open(uint16_t vid, const uint16_t *pids, int npids, uint16_t *opened_pid) {
    if (!pids) return NULL;
    for (int i = 0; i < npids; i++) {
        cusb_dev *d = open_one(vid, pids[i]);
        if (d) {
            if (opened_pid) *opened_pid = pids[i];
            return d;
        }
    }
    return NULL;
}

void cusb_close(cusb_dev *d) {
    if (!d) return;
    if (d->dev) (*d->dev)->Release(d->dev);
    free(d);
}

int cusb_control(cusb_dev *d, uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
                 void *data, uint16_t length, uint32_t timeout_ms) {
    if (!d || !d->dev) return -(int)(kIOReturnNoDevice & 0xffff);
    if (timeout_ms == 0) timeout_ms = CUSB_DEFAULT_TIMEOUT_MS;
    IOUSBDevRequestTO r;
    r.bmRequestType = bmRequestType;
    r.bRequest = bRequest;
    r.wValue = wValue;
    r.wIndex = wIndex;
    r.wLength = length;
    r.pData = data;
    r.wLenDone = 0;
    r.noDataTimeout = timeout_ms;
    r.completionTimeout = timeout_ms;
    IOReturn kr = (*d->dev)->DeviceRequestTO(d->dev, &r);
    return kr == kIOReturnSuccess ? (int)r.wLenDone : -(int)(kr & 0xffff);
}

// ---- Hotplug ----

typedef struct {
    cusb_hotplug_cb cb;
    void *ctx;
    int attached; // Wert fuer den Callback
} watch_ref;

// Iterator leeren; Rueckgabe: Anzahl gefundener Objekte.
static int drain(io_iterator_t it) {
    int n = 0;
    io_object_t o;
    while ((o = IOIteratorNext(it)) != 0) {
        IOObjectRelease(o);
        n++;
    }
    return n;
}

static void watch_handler(void *refcon, io_iterator_t it) {
    watch_ref *w = (watch_ref *)refcon;
    int n = drain(it);
    if (n > 0 && w->cb) w->cb(w->ctx, w->attached);
}

int cusb_watch(uint16_t vid, const uint16_t *pids, int npids, cusb_hotplug_cb cb, void *ctx) {
    if (!cb || !pids || npids <= 0) return -1;
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) return -2;

    CFRunLoopSourceRef src = IONotificationPortGetRunLoopSource(port);
    if (!src) {
        IONotificationPortDestroy(port);
        return -5;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);

    // Je PID ein Anstecken- und ein Abziehen-Paar. Refs und Port leben bewusst bis Prozessende
    // (Watch wird nur einmal eingerichtet). Bei Fehlern bleiben bereits eingerichtete PIDs aktiv.
    int registered = 0;
    for (int i = 0; i < npids; i++) {
        watch_ref *up = (watch_ref *)calloc(1, sizeof(*up));
        watch_ref *down = (watch_ref *)calloc(1, sizeof(*down));
        CFMutableDictionaryRef mUp = make_matching(vid, pids[i]);
        CFMutableDictionaryRef mDown = make_matching(vid, pids[i]);
        if (!up || !down || !mUp || !mDown) {
            free(up);
            free(down);
            if (mUp) CFRelease(mUp);
            if (mDown) CFRelease(mDown);
            continue;
        }
        up->cb = cb; up->ctx = ctx; up->attached = 1;
        down->cb = cb; down->ctx = ctx; down->attached = 0;

        io_iterator_t itUp = 0, itDown = 0;
        kern_return_t kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, mUp,
                                                            watch_handler, up, &itUp); // verbraucht mUp
        if (kr != KERN_SUCCESS) {
            CFRelease(mDown);
            free(up);
            free(down);
            continue;
        }
        kr = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, mDown,
                                              watch_handler, down, &itDown); // verbraucht mDown
        if (kr != KERN_SUCCESS) {
            IOObjectRelease(itUp);
            free(up);
            free(down);
            continue;
        }
        registered++;
        // Beide Iteratoren scharf schalten; bereits angeschlossene Geraete melden.
        watch_handler(up, itUp);
        watch_handler(down, itDown);
    }
    if (registered == 0) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        IONotificationPortDestroy(port);
        return -6;
    }
    return 0;
}
