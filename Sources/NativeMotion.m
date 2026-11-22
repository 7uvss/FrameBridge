#import "NativeMotion.h"
#import "MetalEngine.h"
@implementation NativeMotion {
    Interpolator *_model;
    MetalEngine *_predictor;
    dispatch_queue_t _predictionQueue;
    VTPixelTransferSessionRef _transfer;
    CVPixelBufferPoolRef _low, _high;
    __weak VTFrameProcessorFrame *_lastOriginal;
    VTFrameProcessorFrame *_lastSmall;
}
- (void)installPredictor:(MetalEngine *)predictor { _predictor=predictor; }
static CVPixelBufferPoolRef makePool(int w,int h) {
    CVPixelBufferPoolRef pool=NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@(w),(id)kCVPixelBufferHeightKey:@(h),
       (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
       (id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&pool);
    return pool;
}
- (instancetype)initWithWidth:(int)width height:(int)height modelWidth:(int)mw modelHeight:(int)mh error:(NSError **)error {
    if(!(self=[super init]))return nil;
    if(VTPixelTransferSessionCreate(NULL,&_transfer) || !(_low=makePool(mw,mh)) || !(_high=makePool(width,height))){
        *error=FrameError(@"插帧缩放缓冲创建失败");return nil;
    }
    VTSessionSetProperty(_transfer,kVTPixelTransferPropertyKey_RealTime,kCFBooleanTrue);
    _predictionQueue=dispatch_queue_create("FrameBridge.detail",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    _model=[[Interpolator alloc] initWithWidth:mw height:mh error:error];
    return _model?self:nil;
}
- (VTFrameProcessorFrame *)scale:(VTFrameProcessorFrame *)src pool:(CVPixelBufferPoolRef)pool error:(NSError **)error {
    CVPixelBufferRef pb=NULL;
    if(CVPixelBufferPoolCreatePixelBuffer(NULL,pool,&pb)){*error=FrameError(@"插帧缩放缓冲分配失败");return nil;}
    OSStatus err=VTPixelTransferSessionTransferImage(_transfer,src.buffer,pb);
    VTFrameProcessorFrame *f=nil;
    if(!err) f=[[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:src.presentationTimeStamp];
    CVPixelBufferRelease(pb);
    if(!f) *error=FrameError([NSString stringWithFormat:@"插帧缩放失败 (%d)",(int)err]);
    return f;
}
- (VTFrameProcessorFrame *)guidedMidpointFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error {
    // The predictor has independent mutable scratch textures from the renderer.
    if(!_predictor) _predictor=[[MetalEngine alloc] initWithError:error];
    if(!_predictor) return nil;
    dispatch_group_t pending=dispatch_group_create();
    __block VTFrameProcessorFrame *donor=nil;
    dispatch_group_async(pending,_predictionQueue,^{ @autoreleasepool {
        NSError *predictError=nil;
        donor=[self->_predictor detailDonorFrom:a to:b error:&predictError];
    }});
    BOOL contiguous=(_lastOriginal==a);
    VTFrameProcessorFrame *prev=contiguous ? _lastSmall : [self scale:a pool:_low error:error];
    VTFrameProcessorFrame *next=prev ? [self scale:b pool:_low error:error] : nil;
    VTFrameProcessorFrame *small=next ? [_model midpointFrom:prev to:next error:error] : nil;
    VTFrameProcessorFrame *guide=small ? [self scale:small pool:_high error:error] : nil;
    if(next){ _lastOriginal=b; _lastSmall=next; }
    dispatch_group_wait(pending,DISPATCH_TIME_FOREVER);
    if(!guide || !donor) return guide;
    return [_predictor restoreDetailIn:guide from:donor left:a right:b error:error] ?: guide;
}
- (void)dealloc {
    if(_low)CVPixelBufferPoolRelease(_low);
    if(_high)CVPixelBufferPoolRelease(_high);
    if(_transfer){VTPixelTransferSessionInvalidate(_transfer);CFRelease(_transfer);}
}
@end
