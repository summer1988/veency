#include <substrate.h>

#include <rfb/rfb.h>
#include <rfb/keysym.h>

#include <mach/mach_port.h>

#import <QuartzCore/CAWindowServer.h>
#import <QuartzCore/CAWindowServerDisplay.h>

#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOKit/IOKitLib.h>

#define IOMobileFramebuffer "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

static const size_t Width = 320;
static const size_t Height = 480;
static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static const size_t Stride = Width * BytesPerPixel;
static const size_t Size32 = Width * Height;
static const size_t Size8 = Size32 * BytesPerPixel;

static pthread_t thread_;
static rfbScreenInfoPtr screen_;
static bool running_;
static int buttons_;
static int x_, y_;

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
    x_ = x;
    y_ = y;

    int diff = buttons_ ^ buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    mach_port_t purple(0);

    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);

    buttons_ = buttons;

    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        GSSendSystemEvent(&record);
    }

    if ((diff & 0x08) != 0 && (buttons & 0x4) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = GSEventTypeRingerChanged0;

        record.timestamp = GSCurrentEventTimestamp();

        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x2) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        GSSendSystemEvent(&record);
    }

    if (twas != tis || tis) {
        struct {
            struct GSEventRecord record;
            struct {
                struct GSEventRecordInfo info;
                struct GSPathInfo path;
            } data;
        } event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        event.data.info.pathPositions = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:event.record.locationInWindow];
        }

        if (port == 0) {
            if (purple == 0)
                purple = GSCopyPurpleSystemEventPort();
            port = purple;
        }

        GSSendEvent(&event.record, port);
    }

    if (purple != 0)
        mach_port_deallocate(mach_task_self(), purple);
}

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (!down)
        return;

    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    struct {
        struct GSEventRecord record;
        struct GSEventKeyInfo data;
    } event;

    memset(&event, 0, sizeof(event));

    event.record.type = GSEventTypeKeyDown;
    event.record.timestamp = GSCurrentEventTimestamp();
    event.record.size = sizeof(event.data);

    event.data.character = key;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:CGPointMake(x_, y_)];
    }

    if (port != 0)
        GSSendEvent(&event.record, port);
}

static void *VNCServer(IOMobileFramebufferRef fb) {
    CGRect rect(CGRectMake(0, 0, Width, Height));

    CoreSurfaceBufferRef surface(NULL);
    kern_return_t value(IOMobileFramebufferGetLayerDefaultSurface(fb, 0, &surface));
    if (value != 0)
        return NULL;

    int argc(1);
    char *arg0(strdup("VNCServer"));
    char *argv[] = {arg0, NULL};

    io_service_t service(IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOCoreSurfaceRoot")));
    CFMutableDictionaryRef properties(NULL);
    IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, kNilOptions);

    screen_ = rfbGetScreen(&argc, argv, Width, Height, BitsPerSample, 3, BytesPerPixel);
    screen_->desktopName = "iPhone";
    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 5;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    CoreSurfaceBufferLock(surface, kCoreSurfaceLockTypeGimmeVRAM);
    screen_->frameBuffer = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(surface));
    CoreSurfaceBufferUnlock(surface);

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    rfbInitServer(screen_);
    running_ = true;

    rfbRunEventLoop(screen_, -1, true);
    return NULL;

    running_ = false;
    rfbScreenCleanup(screen_);

    CFRelease(surface);

    free(arg0);
    return NULL;
}

static rfbPixel black_[320][480];

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    /*if (
        bounds.origin.x != 0 || bounds.origin.y != 0 || bounds.size.width != 320 || bounds.size.height != 480 ||
        frame.origin.x != 0 || frame.origin.y != 0 || frame.size.width != 320 || frame.size.height != 480
    ) NSLog(@"VNC:%f,%f:%f,%f:%f,%f:%f,%f",
        bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
        frame.origin.x, frame.origin.y, frame.size.width, frame.size.height
    );*/

    if (running_) {
        if (buffer == NULL)
            screen_->frameBuffer = reinterpret_cast<char *>(black_);
        else {
            CoreSurfaceBufferLock(buffer, kCoreSurfaceLockTypeGimmeVRAM);
            rfbPixel (*data)[480] = reinterpret_cast<rfbPixel (*)[480]>(CoreSurfaceBufferGetBaseAddress(buffer));
            /*memcpy(black_, data, sizeof(black_));
            screen_->frameBuffer = reinterpret_cast<char *>(black_);*/
            data[x_][y_] = screen_->whitePixel;
            screen_->frameBuffer = reinterpret_cast<char *>(data);
            CoreSurfaceBufferUnlock(buffer);
        }
    }

    kern_return_t value(_IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags));

    if (thread_ == NULL)
        pthread_create(&thread_, NULL, &VNCServer, fb);
    else if (running_)
        rfbMarkRectAsModified(screen_, 0, 0, Width, Height);

    return value;
}

extern "C" void TweakInitialize() {
    if (objc_getClass("SpringBoard") == nil)
        return;
    MSHookFunction(&IOMobileFramebufferSwapSetLayer, &$IOMobileFramebufferSwapSetLayer, &_IOMobileFramebufferSwapSetLayer);
}