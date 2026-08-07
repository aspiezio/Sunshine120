/**
 * @file src/platform/macos/av_video.h
 * @brief Declarations for video capture on macOS (ScreenCaptureKit backend).
 */
#pragma once

// platform includes
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

/**
 * @brief Objective-C block invoked for each captured sample buffer.
 */
typedef bool (^FrameCallbackBlock)(CMSampleBufferRef);

/**
 * @brief ScreenCaptureKit video capture controller used by the macOS backend.
 *
 * Drop-in replacement for the previous AVFoundation (AVCaptureScreenInput)
 * implementation. AVCaptureScreenInput refuses to deliver above ~90 fps on
 * Apple Silicon regardless of minFrameDuration; SCK honors
 * SCStreamConfiguration.minimumFrameInterval and delivers up to the display
 * refresh. The public interface is unchanged so display.mm and
 * nv12_zero_device build without modification.
 */
API_AVAILABLE(macos(12.3))
@interface AVVideo: NSObject <SCStreamDelegate, SCStreamOutput>

/**
 * @brief Display ID property.
 */
@property (nonatomic, assign) CGDirectDisplayID displayID;
/**
 * @brief Min frame duration property (1 / requested fps). Maps to
 *        SCStreamConfiguration.minimumFrameInterval.
 */
@property (nonatomic, assign) CMTime minFrameDuration;
/**
 * @brief Pixel format property.
 */
@property (nonatomic, assign) OSType pixelFormat;
/**
 * @brief Frame width property.
 */
@property (nonatomic, assign) int frameWidth;
/**
 * @brief Frame height property.
 */
@property (nonatomic, assign) int frameHeight;

/**
 * @brief Initialize capture for a display and frame rate.
 *
 * @param displayID Display ID.
 * @param frameRate Requested frame rate (fps).
 * @return Initialized AVVideo instance, or nil on failure.
 */
- (id)initWithDisplay:(CGDirectDisplayID)displayID frameRate:(int)frameRate;

/**
 * @brief Set frame width and frame height.
 *
 * @param frameWidth Frame width.
 * @param frameHeight Frame height.
 */
- (void)setFrameWidth:(int)frameWidth frameHeight:(int)frameHeight;

/**
 * @brief Start the capture stream and route frames to @p frameCallback.
 *
 * The returned semaphore is signaled when capture stops (callback returns
 * false, the stream errors, or the object is torn down), matching the
 * blocking contract the C++ capture loop relies on.
 *
 * @param frameCallback Frame callback. Returning false stops the backend.
 * @return Semaphore signaled on capture stop.
 */
- (dispatch_semaphore_t)capture:(FrameCallbackBlock)frameCallback;

@end
