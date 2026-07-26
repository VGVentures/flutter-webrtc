#if TARGET_OS_OSX

#import <FlutterMacOS/FlutterMacOS.h>
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

#import "FlutterWebRTCPlugin.h"

// VGV fork addition (vgv/macos-window-capture): expose a native
// `RTCMTLVideoView` bound to an existing, in-process `RTCVideoTrack` (looked
// up by track id via `-trackForId:peerConnectionId:`) so a native AppKit window
// — the huddle video overlay panel that floats over every app — can render
// participant camera video WITHOUT opening a second LiveKit connection. The
// track already lives in-process (flutter_webrtc runs on WebRTC.framework), so
// this only attaches a native renderer to it. macOS-only.
//
// Flow: Dart drives creation/attachment over the `FlutterWebRTC.Method`
// MethodChannel (handled in `-handleNativeVideoViewMethodCall:result:`, which
// stashes each `RTCMTLVideoView` in a class-static registry keyed by an opaque
// handle string) and the native Runner fetches the concrete NSView for a handle
// via `+nativeVideoViewForHandle:` to embed it in its own window.
@interface FlutterWebRTCPlugin (NativeVideoView)

// Dispatches the `nativeVideoView*` MethodChannel calls. Returns YES when the
// call was one of ours (and `result` has been / will be invoked), NO otherwise.
- (BOOL)handleNativeVideoViewMethodCall:(nonnull FlutterMethodCall*)call
                                 result:(nonnull FlutterResult)result;

// Runner-facing: the concrete `RTCMTLVideoView` for a handle previously
// returned by `nativeVideoViewCreate`, or nil if unknown. Call on the main
// thread; embed the returned view in a native window's content view.
+ (RTCMTLVideoView* _Nullable)nativeVideoViewForHandle:(nonnull NSString*)handle;

@end

#endif
