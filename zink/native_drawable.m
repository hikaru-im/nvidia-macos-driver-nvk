/* SPDX-License-Identifier: MIT */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include "nvk_perf.h"
#import <IOKit/IOKitLib.h>
#include "native_drawable.h"
#include <string.h>

@interface NVKZinkTarget : NSObject
@property(weak) NSView *view;
@property(strong) CAMetalLayer *layer;
@property uint32_t deviceID;
@property unsigned width, height;
@property BOOL pending, opaque, displaySync;
@end
@implementation NVKZinkTarget
@end
@interface NVKZinkFrame : NSObject
@property(strong) id<CAMetalDrawable> drawable;
@property(strong) CAMetalLayer *layer;
@end
@implementation NVKZinkFrame
@end

static NSMutableDictionary<NSValue *, NVKZinkTarget *> *bindings(void)
{
   static NSMutableDictionary *table;
   static dispatch_once_t once;
   dispatch_once(&once, ^{ table = [NSMutableDictionary new]; });
   return table;
}

/* Match the actual NVK PCI device, not MTLCreateSystemDefaultDevice (which
 * can choose an Intel iGPU). Ambiguous identical NVIDIA cards are refused,
 * matching the native Minecraft runtime's current qualification limit. */
static id<MTLDevice> metal_device(uint32_t vendor, uint32_t deviceID)
{
   if (vendor != 0x10de) return nil;
   io_iterator_t iterator = 0;
   if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("NVAccel"), &iterator)) return nil;
   uint64_t selected = 0; unsigned matches = 0;
   for (io_service_t service; (service = IOIteratorNext(iterator)); IOObjectRelease(service)) {
      io_registry_entry_t parent = 0;
      if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)) continue;
      CFTypeRef data = IORegistryEntryCreateCFProperty(parent, CFSTR("device-id"), NULL, 0);
      uint32_t candidate = 0;
      if (data && CFGetTypeID(data) == CFDataGetTypeID() && CFDataGetLength(data) >= 4)
         memcpy(&candidate, CFDataGetBytePtr(data), 4);
      if (data) CFRelease(data);
      IOObjectRelease(parent);
      if (candidate == deviceID) { IORegistryEntryGetRegistryEntryID(service, &selected); ++matches; }
   }
   IOObjectRelease(iterator);
   if (matches != 1) return nil;
   for (id<MTLDevice> device in MTLCopyAllDevices())
      if (device.registryID == selected) return device;
   return nil;
}

/* Display-GPU selection is opt-in. NVK rendering remains on NVIDIA. */
static id<MTLDevice> metal_display_device(NSView *view)
{
   NSScreen *screen = view.window.screen ?: [NSScreen mainScreen];
   NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
   if (!number) return nil;
   return CGDirectDisplayCopyCurrentMetalDevice((CGDirectDisplayID)number.unsignedIntValue);
}

void nvk_native_bind_view(CGLContextObj context, void *pointer)
{
   const char *mode = getenv("NVKZINK_PRESENT");
   if (!context || ![NSThread isMainThread] ||
       (mode && strcmp(mode, "native") && strcmp(mode, "auto"))) return;
   NSView *view = (__bridge NSView *)pointer;
   NSMutableDictionary *table = bindings();
   @synchronized(table) {
      NSValue *key = [NSValue valueWithPointer:context];
      NVKZinkTarget *target = table[key];
      if (!target && view) { target = [NVKZinkTarget new]; table[key] = target; }
      @synchronized(target) {
         if (target.view != view) {
            [target.layer removeFromSuperlayer]; target.layer = nil;
            target.view = view; target.width = target.height = 0;
         }
      }
   }
}

void nvk_native_remove(CGLContextObj context)
{
   NSMutableDictionary *table = bindings();
   NVKZinkTarget *target;
   @synchronized(table) {
      NSValue *key = [NSValue valueWithPointer:context];
      target = table[key]; [table removeObjectForKey:key];
   }
   if (!target) return;
   void (^remove)(void) = ^{
      @synchronized(target) { [target.layer removeFromSuperlayer]; target.layer = nil; target.view = nil; }
   };
   if ([NSThread isMainThread]) remove(); else dispatch_async(dispatch_get_main_queue(), remove);
}

static void configure(NVKZinkTarget *target, uint32_t vendor, uint32_t deviceID,
                       unsigned width, unsigned height, BOOL opaque, BOOL displaySync)
{
   NSCAssert([NSThread isMainThread], @"Layer configuration belongs to main");
   id<MTLDevice> device = metal_device(vendor, deviceID);
   @synchronized(target) {
      NSView *view = target.view;
      target.pending = NO;
      if (!view) return;
      const char *choice = getenv("NVKZINK_DRAWABLE_DEVICE");
      if (choice && strcmp(choice, "display") == 0) {
         /* Do not fall back silently if the display device is unavailable. */
         device = metal_display_device(view);
         if (!device) {
            fprintf(stderr, "NVK Zink: requested display GPU has no Metal device\n");
            return;
         }
      }
      if (!device) return;
      if (!target.layer) {
         fprintf(stderr, "NVK Zink: drawable Metal device=%s registry=%llu mode=%s\n",
                 device.name.UTF8String, (unsigned long long)device.registryID,
                 choice && strcmp(choice, "display") == 0 ? "display (experimental)" : "nvidia (default)");
         view.wantsLayer = YES;
         CAMetalLayer *layer = [CAMetalLayer layer];
         layer.frame = view.bounds;
         layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
         layer.framebufferOnly = NO;
         layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
         layer.maximumDrawableCount = 3;
         layer.allowsNextDrawableTimeout = YES;
         [view.layer addSublayer:layer];
         target.layer = layer;
      }
      target.layer.device = device;
      target.layer.opaque = opaque;
      target.opaque = opaque;
      /* CGLSetParameter updates the Apple context carrier, but our native
       * drawable bypasses Apple's swap. Mirror its requested interval here;
       * CAMetalLayer otherwise enables display synchronization by default. */
      target.layer.displaySyncEnabled = displaySync;
      target.displaySync = displaySync;
      target.layer.frame = view.bounds;
      target.layer.contentsScale = view.wantsBestResolutionOpenGLSurface ? view.window.backingScaleFactor : 1;
      target.layer.drawableSize = CGSizeMake(width, height);
      target.deviceID = deviceID; target.width = width; target.height = height;
   }
}

int nvk_native_acquire(CGLContextObj context, uint32_t vendor, uint32_t deviceID,
                       unsigned width, unsigned height, int opaque, void **frame, IOSurfaceRef *surface)
{
   if (!context || !frame || !surface || !width || !height) return 0;
   *frame = NULL; *surface = NULL;
   GLint interval = 1;
   CGLGetParameter(context, kCGLCPSwapInterval, &interval);
   BOOL displaySync = interval != 0;
   @autoreleasepool {
      @try {
         NSMutableDictionary *table = bindings();
         NVKZinkTarget *target;
         @synchronized(table) { target = table[[NSValue valueWithPointer:context]]; }
         if (!target && [NSThread isMainThread]) {
            NSOpenGLContext *current = [NSOpenGLContext currentContext];
            if (current.CGLContextObj == context && current.view)
               nvk_native_bind_view(context, (__bridge void *)current.view);
            @synchronized(table) { target = table[[NSValue valueWithPointer:context]]; }
         }
         if (!target) return NVK_NATIVE_NO_VIEW;
         BOOL setup = NO;
         @synchronized(target) {
            if (!target.view) return NVK_NATIVE_NO_VIEW;
            if (!target.pending && (!target.layer || target.deviceID != deviceID ||
                                    target.width != width || target.height != height ||
                                    target.opaque != (opaque != 0) || target.displaySync != displaySync)) {
               target.pending = YES; setup = YES;
            }
         }
         if (setup) {
            if ([NSThread isMainThread]) configure(target, vendor, deviceID, width, height, opaque != 0, displaySync);
            else dispatch_async(dispatch_get_main_queue(), ^{ configure(target, vendor, deviceID, width, height, opaque != 0, displaySync); });
         }
         CAMetalLayer *layer;
         @synchronized(target) {
            if (target.pending) return 2;
            layer = target.layer;
            if (!layer) return 0;
            if (target.width != width || target.height != height || target.deviceID != deviceID ||
                target.opaque != (opaque != 0) || target.displaySync != displaySync) return 2;
         }
         const int profiling = nvk_perf_enabled();
         const uint64_t acquired_at = profiling ? nvk_perf_clock() : 0;
         id<CAMetalDrawable> drawable = [layer nextDrawable];
         if (profiling) {
            const uint64_t done_at = nvk_perf_clock();
            static _Thread_local struct nvk_perf_stats stats;
            static const char *const labels[4] = {"nextDrawable", NULL, NULL, NULL};
            const double values[4] = {nvk_perf_ms(acquired_at, done_at), 0, 0, 0};
            nvk_perf_record(&stats, "drawable", 1, labels, values);
         }
         if (!drawable) return 2;
         id<MTLTexture> texture = drawable.texture;
         if (texture.width != width || texture.height != height) return 2;
         if (texture.device.registryID != layer.device.registryID || !texture.iosurface ||
             texture.iosurfacePlane != 0 || texture.pixelFormat != MTLPixelFormatBGRA8Unorm) {
            static dispatch_once_t warned;
            dispatch_once(&warned, ^{
               fprintf(stderr, "NVK Zink: incompatible drawable texture / IOSurface; no CPU fallback\n");
            });
            return 0;
         }
         NVKZinkFrame *item = [NVKZinkFrame new];
         item.drawable = drawable; item.layer = layer;
         *surface = texture.iosurface;
         *frame = (__bridge_retained void *)item;
         return 1;
      } @catch (NSException *exception) {
         fprintf(stderr, "NVK Zink: acquiring native drawable failed: %s\n", exception.reason.UTF8String);
         return 0;
      }
   }
}

int nvk_native_publish(void *frame)
{
   if (!frame) return 0;
   @autoreleasepool {
      @try { [((__bridge NVKZinkFrame *)frame).drawable present]; return 1; }
      @catch (NSException *exception) {
         fprintf(stderr, "NVK Zink: native drawable publication failed: %s\n", exception.reason.UTF8String);
         return 0;
      }
   }
}

void nvk_native_release(void *frame)
{
   if (frame) { @autoreleasepool { id item = CFBridgingRelease(frame); (void)item; } }
}
