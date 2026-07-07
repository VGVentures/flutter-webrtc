#import "FlutterScreenCaptureKitCapturer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

@interface FlutterScreenCaptureKitCapturer ()
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
<SCStreamOutput, SCStreamDelegate>
#endif
@property(nonatomic, strong) RTCVideoCapturer *capturer;
@property(nonatomic, weak) id<RTCVideoCapturerDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t captureQueue;
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
@property(nonatomic, strong) SCStream *stream;
#endif
// VGV fork: set only for the filter-based (picker) path. Invoked once when the
// stream stops for a reason other than an explicit stopCaptureWithCompletion:.
@property(nonatomic, copy) void (^onStoppedHandler)(void);
// VGV fork: guards against a double onStopped/stop race between the explicit
// teardown and an OS-initiated didStopWithError.
@property(nonatomic, assign) BOOL stopped;
@end

@implementation FlutterScreenCaptureKitCapturer

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _capturer = [[RTCVideoCapturer alloc] initWithDelegate:delegate];
    _captureQueue = dispatch_queue_create("com.iperius.sck.capture", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                  onStarted:(void (^)(NSError * _Nullable error))onStarted {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      if (error != nil) {
        onStarted(error);
        return;
      }

      SCDisplay *display = [self selectDisplayFromContent:content sourceId:sourceId];
      if (display == nil) {
        NSError *noDisplay = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"No matching display"}];
        onStarted(noDisplay);
        return;
      }

      SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
      SCStreamConfiguration *config = [SCStreamConfiguration new];
      config.width = display.width;
      config.height = display.height;
      config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
      config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
      if (@available(macOS 13.0, *)) {
        config.showsCursor = YES;
      }

      self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
      NSError *addOutputError = nil;
      [self.stream addStreamOutput:self
                              type:SCStreamOutputTypeScreen
               sampleHandlerQueue:self.captureQueue
                            error:&addOutputError];
      if (addOutputError != nil) {
        onStarted(addOutputError);
        return;
      }

      [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        onStarted(startError);
      }];
    }];
    return;
  }
#endif

  NSError *unavailable = [NSError errorWithDomain:@"FlutterScreenCaptureKit"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"ScreenCaptureKit not available"}];
  onStarted(unavailable);
}

// VGV fork addition (vgv/macos-window-capture): capture the exact
// SCContentFilter the user picked in SCContentSharingPicker — display, window,
// or application. ScreenCaptureKit captures any filter type natively, so this
// is the whole fix for true window/app sharing: we hand the picker's filter
// straight to the SCStream instead of collapsing it to a display id.
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (void)startCaptureWithFilter:(SCContentFilter*)filter
                           fps:(NSInteger)fps
                     onStarted:(void (^)(NSError* _Nullable error))onStarted
                     onStopped:(void (^)(void))onStopped
    API_AVAILABLE(macos(14.0)) {
  self.onStoppedHandler = onStopped;
  self.stopped = NO;

  SCStreamConfiguration* config = [SCStreamConfiguration new];
  // Size the capture to the filter's own content rect in pixels. contentRect
  // is in points; multiply by the point-to-pixel scale so a Retina window is
  // captured at full resolution. This is correct for display, window, and
  // application filters alike — the filter reports the bounds of exactly what
  // was selected.
  CGFloat scale = filter.pointPixelScale > 0 ? filter.pointPixelScale : 1;
  CGSize sizePx = CGSizeMake(filter.contentRect.size.width * scale,
                             filter.contentRect.size.height * scale);
  // Guard against a zero/absurd size (a just-minimised window can briefly
  // report an empty rect); fall back to the main display size.
  if (sizePx.width < 2 || sizePx.height < 2) {
    CGDirectDisplayID main = CGMainDisplayID();
    sizePx = CGSizeMake(CGDisplayPixelsWide(main), CGDisplayPixelsHigh(main));
  }
  config.width = (size_t)sizePx.width;
  config.height = (size_t)sizePx.height;
  config.minimumFrameInterval = CMTimeMake(1, (int32_t)MAX(1, fps));
  config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  config.showsCursor = YES;

  // delegate:self so didStopWithError: reaches us for OS-initiated stops
  // (the user hits the system "Stop Sharing" control, or the window closes).
  self.stream = [[SCStream alloc] initWithFilter:filter
                                   configuration:config
                                        delegate:self];
  NSError* addOutputError = nil;
  [self.stream addStreamOutput:self
                          type:SCStreamOutputTypeScreen
           sampleHandlerQueue:self.captureQueue
                         error:&addOutputError];
  if (addOutputError != nil) {
    onStarted(addOutputError);
    return;
  }
  [self.stream startCaptureWithCompletionHandler:^(NSError* _Nullable startError) {
    onStarted(startError);
  }];
}
#endif

- (void)stopCaptureWithCompletion:(void (^)(void))completion {
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
  if (@available(macOS 12.3, *)) {
    // Explicit teardown: suppress any onStopped callback that a concurrent
    // didStopWithError: might otherwise fire.
    self.stopped = YES;
    self.onStoppedHandler = nil;
    if (self.stream == nil) {
      completion();
      return;
    }
    SCStream *stream = self.stream;
    self.stream = nil;
    [stream stopCaptureWithCompletionHandler:^(__unused NSError * _Nullable error) {
      completion();
    }];
    return;
  }
#endif
  completion();
}

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (SCDisplay *)selectDisplayFromContent:(SCShareableContent *)content
                               sourceId:(NSString *)sourceId API_AVAILABLE(macos(12.3)) {
  if (content.displays.count == 0) {
    return nil;
  }

  if (sourceId != nil && sourceId.length > 0) {
    for (SCDisplay *display in content.displays) {
      if ([[NSString stringWithFormat:@"%u", display.displayID] isEqualToString:sourceId]) {
        return display;
      }
    }
  }

  CGDirectDisplayID mainDisplay = CGMainDisplayID();
  for (SCDisplay *display in content.displays) {
    if (display.displayID == mainDisplay) {
      return display;
    }
  }

  return content.displays.firstObject;
}

- (void)stream:(SCStream *)stream
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (pixelBuffer == nil) {
    return;
  }

  CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  int64_t timeStampNs = (int64_t)(CMTimeGetSeconds(timestamp) * 1000000000.0);

  id<RTCVideoFrameBuffer> rtcBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
  RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcBuffer
                                                      rotation:RTCVideoRotation_0
                                                   timeStampNs:timeStampNs];
  [self.delegate capturer:self.capturer didCaptureVideoFrame:frame];
}

// VGV fork: SCStreamDelegate. Fires when the stream stops for a reason other
// than our explicit stopCaptureWithCompletion: — the system "Stop Sharing"
// control, the source window/app closing, or a capture error. Notify the
// caller so it unpublishes the track. Guarded by `stopped` so an explicit
// teardown does not also fire onStopped.
- (void)stream:(SCStream *)stream
    didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
  void (^handler)(void) = self.onStoppedHandler;
  if (self.stopped || handler == nil) {
    return;
  }
  self.stopped = YES;
  self.onStoppedHandler = nil;
  self.stream = nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    handler();
  });
}
#endif

@end
