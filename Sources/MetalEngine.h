#import <MetalKit/MetalKit.h>
#import "Interpolator.h"

@interface MetalEngine : NSObject
@property(readonly) id<MTLDevice> device;
@property(readonly) id<MTLLibrary> library;
@property(readonly) id<MTLCommandQueue> commands;
- (instancetype)initWithLibrary:(id<MTLLibrary>)library error:(NSError **)error;
- (instancetype)initWithError:(NSError **)error;
// Only luma is initialized. Use exclusively as the donor for detail restoration.
- (VTFrameProcessorFrame *)detailDonorFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error;
- (VTFrameProcessorFrame *)restoreDetailIn:(VTFrameProcessorFrame *)guide from:(VTFrameProcessorFrame *)prediction
                                  left:(VTFrameProcessorFrame *)left right:(VTFrameProcessorFrame *)right error:(NSError **)error;
- (CVMetalTextureRef)plane:(int)plane of:(CVPixelBufferRef)pb CF_RETURNS_RETAINED;
- (NSArray<VTFrameProcessorFrame *> *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)count error:(NSError **)error;
// first is a one-based index into the evenly spaced intermediate frames.
- (NSArray<VTFrameProcessorFrame *> *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)count startingAt:(int)first error:(NSError **)error;
- (VTFrameProcessorFrame *)midpointFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error;
@end
