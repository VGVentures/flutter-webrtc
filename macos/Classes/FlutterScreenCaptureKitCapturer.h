#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#endif

@interface FlutterScreenCaptureKitCapturer : NSObject

- (instancetype)initWithDelegate:(id<RTCVideoCapturerDelegate>)delegate;

- (void)startCaptureWithFPS:(NSInteger)fps
                   sourceId:(NSString* _Nullable)sourceId
                  onStarted:(void (^)(NSError * _Nullable error))onStarted;

// VGV fork addition (vgv/macos-window-capture): capture an arbitrary
// SCContentFilter — a display, a window, or an application — chosen from the
// macOS-native SCContentSharingPicker. Unlike the display-only path above,
// this preserves the exact selection so a window pick captures that window.
// `onStopped` fires when the underlying SCStream stops for any reason other
// than an explicit stopCaptureWithCompletion: (e.g. the user hits the system
// "Stop Sharing" control, or the source window closes) so the caller can
// tear the published track down.
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
- (void)startCaptureWithFilter:(SCContentFilter*)filter
                           fps:(NSInteger)fps
                     onStarted:(void (^)(NSError* _Nullable error))onStarted
                     onStopped:(void (^)(void))onStopped
    API_AVAILABLE(macos(14.0));
#endif

- (void)stopCaptureWithCompletion:(void (^)(void))completion;

@end
