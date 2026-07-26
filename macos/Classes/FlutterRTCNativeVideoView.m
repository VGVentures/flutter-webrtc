#if TARGET_OS_OSX

#import "FlutterRTCNativeVideoView.h"

// Class-static registries, guarded by @synchronized([FlutterWebRTCPlugin class]).
// handle -> the native Metal video view.
static NSMutableDictionary<NSString*, RTCMTLVideoView*>* _nativeVideoViews;
// handle -> the track currently rendering into that view (so a re-attach or a
// detach can removeRenderer: from the previous track).
static NSMutableDictionary<NSString*, RTCVideoTrack*>* _nativeVideoViewTracks;

@implementation FlutterWebRTCPlugin (NativeVideoView)

+ (void)ensureNativeVideoViewRegistries {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    _nativeVideoViews = [NSMutableDictionary dictionary];
    _nativeVideoViewTracks = [NSMutableDictionary dictionary];
  });
}

+ (RTCMTLVideoView*)nativeVideoViewForHandle:(NSString*)handle {
  if (!handle) {
    return nil;
  }
  [self ensureNativeVideoViewRegistries];
  @synchronized([FlutterWebRTCPlugin class]) {
    return _nativeVideoViews[handle];
  }
}

- (BOOL)handleNativeVideoViewMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* method = call.method;
  if ([@"nativeVideoViewCreate" isEqualToString:method]) {
    [self nativeVideoViewCreate:result];
    return YES;
  } else if ([@"nativeVideoViewAttach" isEqualToString:method]) {
    [self nativeVideoViewAttach:call.arguments result:result];
    return YES;
  } else if ([@"nativeVideoViewDetach" isEqualToString:method]) {
    [self nativeVideoViewDetach:call.arguments result:result];
    return YES;
  } else if ([@"nativeVideoViewDispose" isEqualToString:method]) {
    [self nativeVideoViewDispose:call.arguments result:result];
    return YES;
  }
  return NO;
}

// Allocates a native Metal video view and returns an opaque handle string. The
// view starts unattached; call nativeVideoViewAttach to bind it to a track.
- (void)nativeVideoViewCreate:(FlutterResult)result {
  if (![RTCMTLVideoView isMetalAvailable]) {
    result([FlutterError errorWithCode:@"nativeVideoViewCreate"
                               message:@"Metal is not available on this device"
                               details:nil]);
    return;
  }
  [FlutterWebRTCPlugin ensureNativeVideoViewRegistries];
  dispatch_async(dispatch_get_main_queue(), ^{
    RTCMTLVideoView* view = [[RTCMTLVideoView alloc] initWithFrame:CGRectZero];
    view.wantsLayer = YES;
    NSString* handle = [[NSUUID UUID] UUIDString];
    @synchronized([FlutterWebRTCPlugin class]) {
      _nativeVideoViews[handle] = view;
    }
    result(handle);
  });
}

// Binds the track with `trackId` to the view for `handle`. Idempotent: a second
// attach with a different track swaps the renderer over.
- (void)nativeVideoViewAttach:(NSDictionary*)args result:(FlutterResult)result {
  NSString* handle = args[@"handle"];
  NSString* trackId = args[@"trackId"];
  if (handle == nil || trackId == nil) {
    result([FlutterError errorWithCode:@"nativeVideoViewAttach"
                               message:@"handle and trackId are required"
                               details:nil]);
    return;
  }
  RTCMTLVideoView* view = [FlutterWebRTCPlugin nativeVideoViewForHandle:handle];
  if (view == nil) {
    result([FlutterError errorWithCode:@"nativeVideoViewAttach"
                               message:@"unknown native video view handle"
                               details:nil]);
    return;
  }
  RTCMediaStreamTrack* track = [self trackForId:trackId peerConnectionId:nil];
  if (![track isKindOfClass:[RTCVideoTrack class]]) {
    result([FlutterError errorWithCode:@"nativeVideoViewAttach"
                               message:@"no video track for trackId"
                               details:nil]);
    return;
  }
  RTCVideoTrack* videoTrack = (RTCVideoTrack*)track;
  dispatch_async(dispatch_get_main_queue(), ^{
    RTCVideoTrack* previous = nil;
    @synchronized([FlutterWebRTCPlugin class]) {
      previous = _nativeVideoViewTracks[handle];
    }
    if (previous != nil && previous != videoTrack) {
      [previous removeRenderer:view];
    }
    [videoTrack addRenderer:view];
    @synchronized([FlutterWebRTCPlugin class]) {
      _nativeVideoViewTracks[handle] = videoTrack;
    }
    result(@(YES));
  });
}

// Stops rendering into the view but keeps the view allocated (so it can be
// re-attached to a different track without a re-create).
- (void)nativeVideoViewDetach:(NSDictionary*)args result:(FlutterResult)result {
  NSString* handle = args[@"handle"];
  if (handle == nil) {
    result([FlutterError errorWithCode:@"nativeVideoViewDetach"
                               message:@"handle is required"
                               details:nil]);
    return;
  }
  RTCMTLVideoView* view = [FlutterWebRTCPlugin nativeVideoViewForHandle:handle];
  dispatch_async(dispatch_get_main_queue(), ^{
    RTCVideoTrack* previous = nil;
    @synchronized([FlutterWebRTCPlugin class]) {
      previous = _nativeVideoViewTracks[handle];
      [_nativeVideoViewTracks removeObjectForKey:handle];
    }
    if (previous != nil && view != nil) {
      [previous removeRenderer:view];
    }
    result(@(YES));
  });
}

// Detaches and forgets the view for `handle`. The Runner must remove it from any
// window's view hierarchy first.
- (void)nativeVideoViewDispose:(NSDictionary*)args result:(FlutterResult)result {
  NSString* handle = args[@"handle"];
  if (handle == nil) {
    result([FlutterError errorWithCode:@"nativeVideoViewDispose"
                               message:@"handle is required"
                               details:nil]);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    RTCMTLVideoView* view = nil;
    RTCVideoTrack* previous = nil;
    @synchronized([FlutterWebRTCPlugin class]) {
      view = _nativeVideoViews[handle];
      previous = _nativeVideoViewTracks[handle];
      [_nativeVideoViews removeObjectForKey:handle];
      [_nativeVideoViewTracks removeObjectForKey:handle];
    }
    if (previous != nil && view != nil) {
      [previous removeRenderer:view];
    }
    [view removeFromSuperview];
    result(@(YES));
  });
}

@end

#endif
