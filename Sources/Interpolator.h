#import <VideoToolbox/VideoToolbox.h>

/// Serial caller. Frames are IOSurface-backed, video-range NV12.
@interface Interpolator : NSObject
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error;
- (VTFrameProcessorFrame *)midpointFrom:(VTFrameProcessorFrame *)previous
                                     to:(VTFrameProcessorFrame *)current error:(NSError **)error;
@end

NSError *FrameError(NSString *message);
VTFrameProcessorFrame *TestFrame(int width, int height, int index);
