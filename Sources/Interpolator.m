#import "Interpolator.h"

NSError *FrameError(NSString *message) {
    return [NSError errorWithDomain:@"FrameBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation Interpolator {
    VTFrameProcessor *_processor;
    CVPixelBufferPoolRef _pool;
}
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    if (!(self = [super init])) return nil;
    VTLowLatencyFrameInterpolationConfiguration *config = nil;
    if (VTLowLatencyFrameInterpolationConfiguration.supported)
        config = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width
                                        frameHeight:height numberOfInterpolatedFrames:1];
    if (!config) {
        *error = FrameError(@"此设备或分辨率不支持 VideoToolbox 低延迟插帧");
        return nil;
    }
    NSMutableDictionary *attrs = [config.destinationPixelBufferAttributes mutableCopy];
    attrs[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    attrs[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) {
        *error = FrameError(@"无法创建插帧像素缓冲池");
        return nil;
    }
    _processor = [VTFrameProcessor new];
    if (![_processor startSessionWithConfiguration:config error:error]) return nil;
    return self;
}
- (VTFrameProcessorFrame *)midpointFrom:(VTFrameProcessorFrame *)previous
                                     to:(VTFrameProcessorFrame *)current error:(NSError **)error {
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pb) != kCVReturnSuccess) {
        *error = FrameError(@"分配中间帧失败");
        return nil;
    }
    CVBufferPropagateAttachments(current.buffer, pb);
    CMTime timestamp = CMTimeAdd(previous.presentationTimeStamp, CMTimeMultiplyByRatio(
        CMTimeSubtract(current.presentationTimeStamp, previous.presentationTimeStamp), 1, 2));
    VTFrameProcessorFrame *mid = [[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:timestamp];
    CVPixelBufferRelease(pb);
    VTLowLatencyFrameInterpolationParameters *params = mid ? [[VTLowLatencyFrameInterpolationParameters alloc]
        initWithSourceFrame:current previousFrame:previous interpolationPhase:@[@0.5] destinationFrames:@[mid]] : nil;
    if (!params) {
        *error = FrameError(@"VideoToolbox 拒绝了这组帧的格式或时间戳");
        return nil;
    }
    return [_processor processWithParameters:params error:error] ? mid : nil;
}
- (void)dealloc {
    [_processor endSession];
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end

VTFrameProcessorFrame *TestFrame(int width, int height, int index) {
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &pb)) return nil;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *plane = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int y = 0; y < height; y++) {
        uint8_t *line = plane + y * stride;
        for (int x = 0; x < width; x++) {
            int u = x + index * 8;
            line[x] = 40 + ((u / 96 + y / 96) % 2) * 100 + (u % 96) / 3;
        }
    }
    memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * (height / 2));
    CVPixelBufferUnlockBaseAddress(pb, 0);
    VTFrameProcessorFrame *f = [[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:CMTimeMake(index * 2,60)];
    CVPixelBufferRelease(pb);
    return f;
}
