/**
 * @file src/platform/macos/av_video.m
 * @brief Definitions for video capture on macOS (ScreenCaptureKit backend).
 *
 * NOTE: This file must be compiled with ARC (-fobjc-arc). See the CMake change
 * in cmake/compile_definitions/macos.cmake.
 */
// local includes
#import "av_video.h"

@interface AVVideo ()
@property (nonatomic, strong) SCStream *stream;  ///< Active SCK stream.
@property (nonatomic, copy) FrameCallbackBlock frameCallback;  ///< Per-frame callback.
@property (nonatomic, strong) dispatch_semaphore_t captureStopSignal;  ///< Signaled on stop.
@property (nonatomic, strong) dispatch_queue_t sampleQueue;  ///< Serial delivery queue.
@property (nonatomic, assign) BOOL stopped;  ///< Guards single-shot teardown.
@end

@implementation AVVideo

- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate {
  self = [super init];
  if (!self) {
    return nil;
  }

  // Query native pixel dimensions up front; display.mm reads frameWidth/
  // frameHeight immediately after init to size the stream.
  CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
  if (!mode) {
    return nil;
  }

  self.displayID = displayID;
  self.pixelFormat = kCVPixelFormatType_32BGRA;
  self.frameWidth = (int) CGDisplayModeGetPixelWidth(mode);
  self.frameHeight = (int) CGDisplayModeGetPixelHeight(mode);
  self.minFrameDuration = CMTimeMake(1, frameRate);
  self.stopped = NO;

  CFRelease(mode);

  return self;
}

- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight {
  self.frameWidth = frameWidth;
  self.frameHeight = frameHeight;
}

/**
 * @brief Resolve the SCDisplay matching self.displayID (synchronous).
 *
 * SCShareableContent enumeration is async; block until it returns to preserve
 * the synchronous init/capture flow the C++ side expects.
 */
- (SCDisplay *)resolveDisplay {
  __block SCDisplay *found = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
    if (!error && content) {
      for (SCDisplay *candidate in content.displays) {
        if (candidate.displayID == self.displayID) {
          found = candidate;
          break;
        }
      }
      // Fall back to the first available display, mirroring the AVFoundation
      // backend's "default to main display" behavior.
      if (found == nil) {
        found = content.displays.firstObject;
      }
    }
    dispatch_semaphore_signal(sem);
  }];

  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  return found;
}

- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback {
  @synchronized(self) {
    self.frameCallback = frameCallback;
    self.stopped = NO;
    self.captureStopSignal = dispatch_semaphore_create(0);

    SCDisplay *display = [self resolveDisplay];
    if (display == nil) {
      dispatch_semaphore_signal(self.captureStopSignal);
      return self.captureStopSignal;
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                     excludingWindows:@[]];

    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = self.frameWidth;
    config.height = self.frameHeight;
    // The whole point of this backend: cap the frame interval at 1/fps instead
    // of letting SCK fall back to its 1/60 default. Content-driven delivery
    // means a game rendering at 120 yields ~120 captured frames.
    config.minimumFrameInterval = self.minFrameDuration;
    config.pixelFormat = self.pixelFormat;
    config.queueDepth = 8;
    config.showsCursor = YES;  // AVCaptureScreenInput embedded the cursor; match it.

    self.sampleQueue = dispatch_queue_create(
      "videoCaptureQueue",
      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));

    self.stream = [[SCStream alloc] initWithFilter:filter
                                     configuration:config
                                          delegate:self];

    NSError *addError = nil;
    if (![self.stream addStreamOutput:self
                                 type:SCStreamOutputTypeScreen
                   sampleHandlerQueue:self.sampleQueue
                                error:&addError]) {
      self.stream = nil;
      dispatch_semaphore_signal(self.captureStopSignal);
      return self.captureStopSignal;
    }

    [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        [self stopStream];
      }
    }];

    return self.captureStopSignal;
  }
}

/**
 * @brief Tear down the stream once and signal the stop semaphore exactly once.
 */
- (void)stopStream {
  SCStream *toStop = nil;
  @synchronized(self) {
    if (self.stopped) {
      return;
    }
    self.stopped = YES;
    toStop = self.stream;
    self.stream = nil;
  }

  if (toStop) {
    [toStop stopCaptureWithCompletionHandler:^(NSError *error) {
      (void) error;
    }];
  }

  if (self.captureStopSignal) {
    dispatch_semaphore_signal(self.captureStopSignal);
  }
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                 ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }
  if (!CMSampleBufferIsValid(sampleBuffer) || CMSampleBufferGetImageBuffer(sampleBuffer) == NULL) {
    return;
  }

  // SCK sends status frames (idle/blank/started/suspended) with no useful
  // pixels. Only forward frames flagged complete.
  NSArray *attachments = (__bridge NSArray *) CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, NO);
  if (attachments.count > 0) {
    NSDictionary *info = attachments[0];
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (status != nil && status.intValue != SCFrameStatusComplete) {
      return;
    }
  }

  FrameCallbackBlock callback = nil;
  @synchronized(self) {
    if (self.stopped) {
      return;
    }
    callback = self.frameCallback;
  }
  if (callback == nil) {
    return;
  }

  // Returning false from the callback means the pipeline wants to stop.
  if (!callback(sampleBuffer)) {
    [self stopStream];
  }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  [self stopStream];
}

- (void)dealloc {
  [self stopStream];
}

@end
