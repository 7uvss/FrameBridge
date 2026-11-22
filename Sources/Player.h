#import "MetalEngine.h"
@interface Player : NSObject <MTKViewDelegate>
@property(readonly) MTKView *view;
- (instancetype)initWithError:(NSError **)error;
// Configure before delivering the first capture sample.
@property(nonatomic) double detailBufferSeconds;
@property(nonatomic,copy) void (^presentationObserver)(CMTime stamp, double presentedTime);
// Mode changes, resets and samples share the serial capture queue.
@property(nonatomic) BOOL nativeOutput;
- (BOOL)installShader:(NSString *)source error:(NSError **)error;
- (void)reset;
- (void)accept:(CVPixelBufferRef)pb pts:(CMTime)pts;
- (NSString *)ratesForInterval:(double)seconds;
- (NSString *)ratesForInterval:(double)seconds captureFPS:(double)fps drops:(NSUInteger)drops;
@end
