#import "Interpolator.h"
@class MetalEngine;
@interface NativeMotion : NSObject
// Called on the same serial queue as guidedMidpointFrom:.
- (void)installPredictor:(MetalEngine *)predictor;
- (instancetype)initWithWidth:(int)width height:(int)height modelWidth:(int)mw modelHeight:(int)mh error:(NSError **)error;
- (VTFrameProcessorFrame *)guidedMidpointFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error;
@end
