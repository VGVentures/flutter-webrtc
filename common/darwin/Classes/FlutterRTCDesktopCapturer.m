#import <objc/runtime.h>

#import "FlutterRTCDesktopCapturer.h"

#if TARGET_OS_IPHONE
#import <ReplayKit/ReplayKit.h>
#import "FlutterBroadcastScreenCapturer.h"
#import "FlutterRPScreenRecorder.h"
#endif

#import "VideoProcessingAdapter.h"
#import "LocalVideoTrack.h"
#if TARGET_OS_OSX
#import "FlutterScreenCaptureKitCapturer.h"
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif
#endif

#if TARGET_OS_OSX
RTCDesktopMediaList* _screen = nil;
RTCDesktopMediaList* _window = nil;
NSArray<RTCDesktopSource*>* _captureSources;
#endif

#if TARGET_OS_OSX && __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
// VGV fork addition (vgv/macos-window-capture): drives one presentation of the
// macOS-native SCContentSharingPicker and, on the Member's pick, starts a
// ScreenCaptureKit capture of that exact SCContentFilter (display / window /
// application). The picker singleton holds only a weak observer reference, so
// the object retains itself in `activeObserver` for the interaction's lifetime
// and releases on the first terminal callback.
API_AVAILABLE(macos(14.0))
@interface FlutterWebRTCScreenSharePicker : NSObject <SCContentSharingPickerObserver>
@property(nonatomic, weak) FlutterWebRTCPlugin* plugin;
@property(nonatomic, copy) FlutterResult result;
@property(nonatomic, assign) BOOL finished;
+ (void)presentForPlugin:(FlutterWebRTCPlugin*)plugin result:(FlutterResult)result;
@end

static FlutterWebRTCScreenSharePicker* _activeScreenSharePicker API_AVAILABLE(macos(14.0));
#endif

@implementation FlutterWebRTCPlugin (DesktopCapturer)

- (void)getDisplayMedia:(NSDictionary*)constraints result:(FlutterResult)result {
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
  RTCVideoSource* videoSource = [self.peerConnectionFactory videoSourceForScreenCast:YES];
  NSString* trackUUID = [[NSUUID UUID] UUIDString];
  VideoProcessingAdapter *videoProcessingAdapter = [[VideoProcessingAdapter alloc] initWithRTCVideoSource:videoSource];
  
#if TARGET_OS_IPHONE
  BOOL useBroadcastExtension = false;
  BOOL presentBroadcastPicker = false;

  id videoConstraints = constraints[@"video"];
  if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
    // constraints.video.deviceId
    useBroadcastExtension =
        [((NSDictionary*)videoConstraints)[@"deviceId"] hasPrefix:@"broadcast"];
    presentBroadcastPicker =
        useBroadcastExtension &&
        ![((NSDictionary*)videoConstraints)[@"deviceId"] hasSuffix:@"-manual"];
  }

  id screenCapturer;

  if (useBroadcastExtension) {
    screenCapturer = [[FlutterBroadcastScreenCapturer alloc] initWithDelegate:videoProcessingAdapter];
  } else {
    screenCapturer = [[FlutterRPScreenRecorder alloc] initWithDelegate:[videoProcessingAdapter source]];
  }

  [screenCapturer startCapture];
  NSLog(@"start %@ capture", useBroadcastExtension ? @"broadcast" : @"replykit");

  self.videoCapturerStopHandlers[trackUUID] = ^(CompletionHandler handler) {
    NSLog(@"stop %@ capture, trackID %@", useBroadcastExtension ? @"broadcast" : @"replykit",
          trackUUID);
    [screenCapturer stopCaptureWithCompletionHandler:handler];
  };

  if (presentBroadcastPicker) {
    NSString* extension =
        [[[NSBundle mainBundle] infoDictionary] valueForKey:kRTCScreenSharingExtension];

    RPSystemBroadcastPickerView* picker = [[RPSystemBroadcastPickerView alloc] init];
    picker.showsMicrophoneButton = false;
    if (extension) {
      picker.preferredExtension = extension;
    } else {
      NSLog(@"Not able to find the %@ key", kRTCScreenSharingExtension);
    }
    SEL selector = NSSelectorFromString(@"buttonPressed:");
    if ([picker respondsToSelector:selector]) {
      [picker performSelector:selector withObject:nil];
    }
  }
#endif

#if TARGET_OS_OSX
  /* example for constraints:
      {
          'audio': false,
          'video": {
              'deviceId':  {'exact': sourceId},
              'mandatory': {
                  'frameRate': 30.0
              },
          }
      }
  */
  NSString* sourceId = nil;
  BOOL useDefaultScreen = NO;
  NSInteger fps = 30;
  id videoConstraints = constraints[@"video"];
  if ([videoConstraints isKindOfClass:[NSNumber class]] && [videoConstraints boolValue] == YES) {
    useDefaultScreen = YES;
  } else if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
    NSDictionary* deviceId = videoConstraints[@"deviceId"];
    if (deviceId != nil && [deviceId isKindOfClass:[NSDictionary class]]) {
      if (deviceId[@"exact"] != nil) {
        sourceId = deviceId[@"exact"];
        if (sourceId == nil) {
          result(@{@"error" : @"No deviceId.exact found"});
          return;
        }
      }
    } else {
      // fall back to default screen if no deviceId is specified
      useDefaultScreen = YES;
    }
    id mandatory = videoConstraints[@"mandatory"];
    if (mandatory != nil && [mandatory isKindOfClass:[NSDictionary class]]) {
      id frameRate = mandatory[@"frameRate"];
      if (frameRate != nil && [frameRate isKindOfClass:[NSNumber class]]) {
        fps = [frameRate integerValue];
      }
    }
  }
  RTCDesktopCapturer* desktopCapturer;
  FlutterScreenCaptureKitCapturer* screenCaptureKitCapturer = nil;
  RTCDesktopSource* source = nil;
  BOOL useScreenCaptureKit = NO;

  if (useDefaultScreen) {
    useScreenCaptureKit = YES;
  } else {
    source = [self getSourceById:sourceId];
    if (source == nil) {
      result(@{@"error" : [NSString stringWithFormat:@"No source found for id: %@", sourceId]});
      return;
    }
    if (source.sourceType == RTCDesktopSourceTypeScreen) {
      useScreenCaptureKit = YES;
    } else {
      desktopCapturer = [[RTCDesktopCapturer alloc] initWithSource:source
                                                          delegate:self
                                                   captureDelegate:videoProcessingAdapter];
    }
  }
  if (useScreenCaptureKit) {
    if (@available(macOS 12.3, *)) {
      screenCaptureKitCapturer =
          [[FlutterScreenCaptureKitCapturer alloc] initWithDelegate:videoProcessingAdapter];
      [screenCaptureKitCapturer startCaptureWithFPS:fps
                                           sourceId:sourceId
                                          onStarted:^(NSError * _Nullable error) {
                                            if (error != nil) {
                                              NSLog(@"ScreenCaptureKit start failed: %@", error);
                                            } else {
                                              NSLog(@"start screencapturekit capture: for  sourceId: %@, fps: %lu",
                                                    sourceId, fps);
                                            }
                                          }];
    } else {
      NSLog(@"ScreenCaptureKit not available, falling back to RTCDesktopCapturer");
      desktopCapturer = [[RTCDesktopCapturer alloc] initWithDefaultScreen:self
                                                          captureDelegate:videoProcessingAdapter];
    }
  }

  if (screenCaptureKitCapturer == nil) {
    [desktopCapturer startCaptureWithFPS:fps];
    NSLog(@"start desktop capture: sourceId: %@, type: %@, fps: %lu", sourceId,
          source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window", fps);

    self.videoCapturerStopHandlers[trackUUID] = ^(CompletionHandler handler) {
      NSLog(@"stop desktop capture: sourceId: %@, type: %@, trackID %@", sourceId,
            source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window", trackUUID);
      [desktopCapturer stopCapture];
      handler();
    };
  } else {
    self.videoCapturerStopHandlers[trackUUID] = ^(CompletionHandler handler) {
      NSLog(@"stop screencapturekit capture: trackID %@", trackUUID);
      [screenCaptureKitCapturer stopCaptureWithCompletion:handler];
    };
  }
#endif

  RTCVideoTrack* videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource
                                                                       trackId:trackUUID];
  [mediaStream addVideoTrack:videoTrack];

  LocalVideoTrack *localVideoTrack = [[LocalVideoTrack alloc] initWithTrack:videoTrack videoProcessing:videoProcessingAdapter];

  [self.localTracks setObject:localVideoTrack forKey:trackUUID];

  NSMutableArray* audioTracks = [NSMutableArray array];
  NSMutableArray* videoTracks = [NSMutableArray array];

  for (RTCVideoTrack* track in mediaStream.videoTracks) {
    [videoTracks addObject:@{
      @"id" : track.trackId,
      @"kind" : track.kind,
      @"label" : track.trackId,
      @"enabled" : @(track.isEnabled),
      @"remote" : @(YES),
      @"readyState" : @"live"
    }];
  }

  self.localStreams[mediaStreamId] = mediaStream;
  result(
      @{@"streamId" : mediaStreamId, @"audioTracks" : audioTracks, @"videoTracks" : videoTracks});
}

#if TARGET_OS_OSX
// VGV fork addition (vgv/macos-window-capture).
- (void)getDisplayMediaWithPicker:(FlutterResult)result {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 14.0, *)) {
    [FlutterWebRTCScreenSharePicker presentForPlugin:self result:result];
    return;
  }
#endif
  result([FlutterError
      errorWithCode:@"unavailable"
            message:@"SCContentSharingPicker requires macOS 14.0 or newer"
            details:nil]);
}
#endif

- (void)getDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
#if TARGET_OS_OSX
  NSLog(@"getDesktopSources");

  NSArray* types = [argsMap objectForKey:@"types"];
  if (types == nil) {
    result([FlutterError errorWithCode:@"ERROR" message:@"types is required" details:nil]);
    return;
  }

  if (![self buildDesktopSourcesListWithTypes:types forceReload:YES result:result]) {
    NSLog(@"getDesktopSources failed.");
    return;
  }

  NSMutableArray* sources = [NSMutableArray array];
  NSEnumerator* enumerator = [_captureSources objectEnumerator];
  RTCDesktopSource* object;
  while ((object = enumerator.nextObject) != nil) {
    /*NSData *data = nil;
    if([object thumbnail]) {
        data = [[NSData alloc] init];
        NSImage *resizedImg = [self resizeImage:[object thumbnail] forSize:NSMakeSize(320, 180)];
        data = [resizedImg TIFFRepresentation];
    }*/
    [sources addObject:@{
      @"id" : object.sourceId,
      @"name" : object.name,
      @"thumbnailSize" : @{@"width" : @0, @"height" : @0},
      @"type" : object.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window",
      //@"thumbnail": data,
    }];
  }
  result(@{@"sources" : sources});
#else
  result([FlutterError errorWithCode:@"ERROR" message:@"Not supported on iOS" details:nil]);
#endif
}

- (void)getDesktopSourceThumbnail:(NSDictionary*)argsMap result:(FlutterResult)result {
#if TARGET_OS_OSX
  NSLog(@"getDesktopSourceThumbnail");
  NSString* sourceId = argsMap[@"sourceId"];
  RTCDesktopSource* object = [self getSourceById:sourceId];
  if (object == nil) {
    result(@{@"error" : @"No source found"});
    return;
  }
  NSImage* image = [object UpdateThumbnail];
  if (image != nil) {
    NSImage* resizedImg = [self resizeImage:image forSize:NSMakeSize(320, 180)];
    NSData* data = [resizedImg TIFFRepresentation];
    result(data);
  } else {
    result(@{@"error" : @"No thumbnail found"});
  }

#else
  result([FlutterError errorWithCode:@"ERROR" message:@"Not supported on iOS" details:nil]);
#endif
}

- (void)updateDesktopSources:(NSDictionary*)argsMap result:(FlutterResult)result {
#if TARGET_OS_OSX
  NSLog(@"updateDesktopSources");
  NSArray* types = [argsMap objectForKey:@"types"];
  if (types == nil) {
    result([FlutterError errorWithCode:@"ERROR" message:@"types is required" details:nil]);
    return;
  }
  if (![self buildDesktopSourcesListWithTypes:types forceReload:NO result:result]) {
    NSLog(@"updateDesktopSources failed.");
    return;
  }
  result(@{@"result" : @YES});
#else
  result([FlutterError errorWithCode:@"ERROR" message:@"Not supported on iOS" details:nil]);
#endif
}

#if TARGET_OS_OSX
- (NSImage*)resizeImage:(NSImage*)sourceImage forSize:(CGSize)targetSize {
  CGSize imageSize = sourceImage.size;
  CGFloat width = imageSize.width;
  CGFloat height = imageSize.height;
  CGFloat targetWidth = targetSize.width;
  CGFloat targetHeight = targetSize.height;
  CGFloat scaleFactor = 0.0;
  CGFloat scaledWidth = targetWidth;
  CGFloat scaledHeight = targetHeight;
  CGPoint thumbnailPoint = CGPointMake(0.0, 0.0);

  if (CGSizeEqualToSize(imageSize, targetSize) == NO) {
    CGFloat widthFactor = targetWidth / width;
    CGFloat heightFactor = targetHeight / height;

    // scale to fit the longer
    scaleFactor = (widthFactor > heightFactor) ? widthFactor : heightFactor;
    scaledWidth = ceil(width * scaleFactor);
    scaledHeight = ceil(height * scaleFactor);

    // center the image
    if (widthFactor > heightFactor) {
      thumbnailPoint.y = (targetHeight - scaledHeight) * 0.5;
    } else if (widthFactor < heightFactor) {
      thumbnailPoint.x = (targetWidth - scaledWidth) * 0.5;
    }
  }

  NSImage* newImage = [[NSImage alloc] initWithSize:NSMakeSize(scaledWidth, scaledHeight)];
  CGRect thumbnailRect = {thumbnailPoint, {scaledWidth, scaledHeight}};
  NSRect imageRect = NSMakeRect(0.0, 0.0, width, height);

  [newImage lockFocus];
    [sourceImage drawInRect:thumbnailRect fromRect:imageRect operation:NSCompositingOperationCopy fraction:1.0];
  [newImage unlockFocus];

  return newImage;
}

- (RTCDesktopSource*)getSourceById:(NSString*)sourceId {
  NSEnumerator* enumerator = [_captureSources objectEnumerator];
  RTCDesktopSource* object;
  while ((object = enumerator.nextObject) != nil) {
    if ([sourceId isEqualToString:object.sourceId]) {
      return object;
    }
  }
  return nil;
}

- (BOOL)buildDesktopSourcesListWithTypes:(NSArray*)types
                             forceReload:(BOOL)forceReload
                                  result:(FlutterResult)result {
  BOOL captureWindow = NO;
  BOOL captureScreen = NO;
  _captureSources = [NSMutableArray array];

  NSEnumerator* typesEnumerator = [types objectEnumerator];
  NSString* type;
  while ((type = typesEnumerator.nextObject) != nil) {
    if ([type isEqualToString:@"screen"]) {
      captureScreen = YES;
    } else if ([type isEqualToString:@"window"]) {
      captureWindow = YES;
    } else {
      result([FlutterError errorWithCode:@"ERROR" message:@"Invalid type" details:nil]);
      return NO;
    }
  }

  if (!captureWindow && !captureScreen) {
    result([FlutterError errorWithCode:@"ERROR"
                               message:@"At least one type is required"
                               details:nil]);
    return NO;
  }

  if (forceReload) {
    _screen = nil;
    _window = nil;
  }

  if (captureWindow) {
    if (!_window)
      _window = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeWindow delegate:self];
    [_window UpdateSourceList:forceReload updateAllThumbnails:YES];
    NSArray<RTCDesktopSource*>* sources = [_window getSources];
    _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
  }
  if (captureScreen) {
    if (!_screen)
      _screen = [[RTCDesktopMediaList alloc] initWithType:RTCDesktopSourceTypeScreen delegate:self];
    [_screen UpdateSourceList:forceReload updateAllThumbnails:YES];
    NSArray<RTCDesktopSource*>* sources = [_screen getSources];
    _captureSources = [_captureSources arrayByAddingObjectsFromArray:sources];
  }
  NSLog(@"captureSources: %lu", [_captureSources count]);
  return YES;
}

#pragma mark - RTCDesktopMediaListDelegate delegate

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)didDesktopSourceAdded:(RTC_OBJC_TYPE(RTCDesktopSource) *)source {
  // NSLog(@"didDesktopSourceAdded: %@, id %@", source.name, source.sourceId);
  if (self.eventSink) {
    NSImage* image = [source UpdateThumbnail];
    NSData* data = [[NSData alloc] init];
    if (image != nil) {
      NSImage* resizedImg = [self resizeImage:image forSize:NSMakeSize(320, 180)];
      data = [resizedImg TIFFRepresentation];
    }
    postEvent(self.eventSink, @{
      @"event" : @"desktopSourceAdded",
      @"id" : source.sourceId,
      @"name" : source.name,
      @"thumbnailSize" : @{@"width" : @0, @"height" : @0},
      @"type" : source.sourceType == RTCDesktopSourceTypeScreen ? @"screen" : @"window",
      @"thumbnail" : data
    });
  }
}

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)didDesktopSourceRemoved:(RTC_OBJC_TYPE(RTCDesktopSource) *)source {
  // NSLog(@"didDesktopSourceRemoved: %@, id %@", source.name, source.sourceId);
  if (self.eventSink) {
    postEvent(self.eventSink, @{
      @"event" : @"desktopSourceRemoved",
      @"id" : source.sourceId,
    });
  }
}

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)didDesktopSourceNameChanged:(RTC_OBJC_TYPE(RTCDesktopSource) *)source {
  // NSLog(@"didDesktopSourceNameChanged: %@, id %@", source.name, source.sourceId);
  if (self.eventSink) {
    postEvent(self.eventSink, @{
      @"event" : @"desktopSourceNameChanged",
      @"id" : source.sourceId,
      @"name" : source.name,
    });
  }
}

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)didDesktopSourceThumbnailChanged:(RTC_OBJC_TYPE(RTCDesktopSource) *)source {
  // NSLog(@"didDesktopSourceThumbnailChanged: %@, id %@", source.name, source.sourceId);
  if (self.eventSink) {
    NSImage* resizedImg = [self resizeImage:[source thumbnail] forSize:NSMakeSize(320, 180)];
    NSData* data = [resizedImg TIFFRepresentation];
    postEvent(self.eventSink, @{
      @"event" : @"desktopSourceThumbnailChanged",
      @"id" : source.sourceId,
      @"thumbnail" : data
    });
  }
}

#pragma mark - RTCDesktopCapturerDelegate delegate

- (void)didSourceCaptureStart:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureStart");
}

- (void)didSourceCapturePaused:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCapturePaused");
}

- (void)didSourceCaptureStop:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureStop");
}

- (void)didSourceCaptureError:(RTCDesktopCapturer*)capturer {
  NSLog(@"didSourceCaptureError");
}

#endif

@end

#if TARGET_OS_OSX && __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
// VGV fork addition (vgv/macos-window-capture): SCContentSharingPicker driver.
@implementation FlutterWebRTCScreenSharePicker

+ (void)presentForPlugin:(FlutterWebRTCPlugin*)plugin
                  result:(FlutterResult)result API_AVAILABLE(macos(14.0)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Only one picker at a time; a second request resolves as a cancel so the
    // caller does not hang.
    if (_activeScreenSharePicker != nil) {
      result(@{@"cancelled" : @YES});
      return;
    }
    FlutterWebRTCScreenSharePicker* observer =
        [[FlutterWebRTCScreenSharePicker alloc] init];
    observer.plugin = plugin;
    observer.result = result;
    _activeScreenSharePicker = observer;

    SCContentSharingPicker* picker = SCContentSharingPicker.sharedPicker;
    SCContentSharingPickerConfiguration* config =
        [[SCContentSharingPickerConfiguration alloc] init];
    // Offer the full Meet-style set: a single window, an application, or a
    // whole display.
    config.allowedPickerModes = SCContentSharingPickerModeSingleWindow |
                                SCContentSharingPickerModeSingleApplication |
                                SCContentSharingPickerModeSingleDisplay;
    picker.defaultConfiguration = config;
    [picker addObserver:observer];
    picker.active = YES;
    [picker present];
  });
}

- (void)finishWithResult:(id)value API_AVAILABLE(macos(14.0)) {
  if (self.finished) {
    return;
  }
  self.finished = YES;
  [SCContentSharingPicker.sharedPicker removeObserver:self];
  SCContentSharingPicker.sharedPicker.active = NO;
  FlutterResult result = self.result;
  self.result = nil;
  _activeScreenSharePicker = nil;
  if (result != nil) {
    result(value);
  }
}

// SCContentSharingPickerObserver

- (void)contentSharingPicker:(SCContentSharingPicker*)picker
         didUpdateWithFilter:(SCContentFilter*)filter
                   forStream:(SCStream*)stream API_AVAILABLE(macos(14.0)) {
  if (self.finished) {
    return;
  }
  FlutterWebRTCPlugin* plugin = self.plugin;
  if (plugin == nil) {
    [self finishWithResult:@{@"cancelled" : @YES}];
    return;
  }

  // Build the WebRTC track exactly as getDisplayMedia does, then drive an
  // SCStream on the picked filter into the same RTCVideoSource. This reuses
  // the plugin's shared factory + track registry, so LiveKit/publish adopts
  // the track by id with no other changes.
  NSString* mediaStreamId = [[NSUUID UUID] UUIDString];
  RTCMediaStream* mediaStream =
      [plugin.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
  RTCVideoSource* videoSource =
      [plugin.peerConnectionFactory videoSourceForScreenCast:YES];
  NSString* trackUUID = [[NSUUID UUID] UUIDString];
  VideoProcessingAdapter* videoProcessingAdapter =
      [[VideoProcessingAdapter alloc] initWithRTCVideoSource:videoSource];

  FlutterScreenCaptureKitCapturer* capturer =
      [[FlutterScreenCaptureKitCapturer alloc]
          initWithDelegate:videoProcessingAdapter];

  __weak FlutterWebRTCPlugin* weakPlugin = plugin;
  [capturer
      startCaptureWithFilter:filter
                         fps:30
                   onStarted:^(NSError* _Nullable error) {
                     if (error != nil) {
                       NSLog(@"screenshare picker capture start failed: %@",
                             error);
                       [self finishWithResult:[FlutterError
                                                  errorWithCode:@"capture-failed"
                                                        message:error
                                                                    .localizedDescription
                                                        details:nil]];
                       return;
                     }
                   }
                   onStopped:^{
                     // OS-initiated stop (system "Stop Sharing" / window
                     // closed). Drop the track + tell Dart to unpublish.
                     FlutterWebRTCPlugin* p = weakPlugin;
                     if (p == nil) {
                       return;
                     }
                     [p.localTracks removeObjectForKey:trackUUID];
                     [p.videoCapturerStopHandlers removeObjectForKey:trackUUID];
                     postEvent(p.eventSink, @{
                       @"event" : @"selectedSourceStopped",
                       @"trackId" : trackUUID,
                     });
                   }];

  RTCVideoTrack* videoTrack =
      [plugin.peerConnectionFactory videoTrackWithSource:videoSource
                                                 trackId:trackUUID];
  [mediaStream addVideoTrack:videoTrack];
  LocalVideoTrack* localVideoTrack =
      [[LocalVideoTrack alloc] initWithTrack:videoTrack
                             videoProcessing:videoProcessingAdapter];
  plugin.localTracks[trackUUID] = localVideoTrack;

  // Explicit-stop handler so the app's stop path (and leaving the huddle)
  // tears the SCStream down.
  plugin.videoCapturerStopHandlers[trackUUID] = ^(CompletionHandler handler) {
    [capturer stopCaptureWithCompletion:handler];
  };
  plugin.localStreams[mediaStreamId] = mediaStream;

  NSString* kind;
  switch (filter.style) {
    case SCShareableContentStyleWindow:
      kind = @"window";
      break;
    case SCShareableContentStyleApplication:
      kind = @"application";
      break;
    case SCShareableContentStyleDisplay:
    default:
      kind = @"display";
      break;
  }

  NSMutableArray* videoTracks = [NSMutableArray array];
  for (RTCVideoTrack* track in mediaStream.videoTracks) {
    [videoTracks addObject:@{
      @"id" : track.trackId,
      @"kind" : track.kind,
      @"label" : track.trackId,
      @"enabled" : @(track.isEnabled),
      @"remote" : @(NO),
      @"readyState" : @"live",
    }];
  }

  [self finishWithResult:@{
    @"streamId" : mediaStreamId,
    @"audioTracks" : @[],
    @"videoTracks" : videoTracks,
    @"source" : @{@"kind" : kind, @"name" : @""},
  }];
}

- (void)contentSharingPicker:(SCContentSharingPicker*)picker
           didCancelForStream:(SCStream*)stream API_AVAILABLE(macos(14.0)) {
  // The Member dismissed the picker without choosing — a no-op.
  [self finishWithResult:@{@"cancelled" : @YES}];
}

- (void)contentSharingPickerStartDidFailWithError:(NSError*)error
    API_AVAILABLE(macos(14.0)) {
  [self finishWithResult:[FlutterError errorWithCode:@"capture-failed"
                                             message:error.localizedDescription
                                             details:nil]];
}

@end
#endif
