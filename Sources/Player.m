#import "Player.h"
#import "NativeMotion.h"
#import <simd/simd.h>
#import <objc/runtime.h>

static char captureArrivalKey;
#import <QuartzCore/QuartzCore.h>

@implementation Player {
    MetalEngine *_engine, *_updatedMotion;
    NativeMotion *_native;
    dispatch_queue_t _nativeQueue;
    BOOL _nativeBusy, _metalBusy;
    dispatch_queue_t _metalQueue;
    NSUInteger _longPairs, _missedSlots;
    NSUInteger _epoch;
    id<MTLRenderPipelineState> _pipeline;
    VTFrameProcessorFrame *_previous, *_displayed;
    VTFrameProcessorFrame *_lastDrawn;
    CGSize _lastDrawSize;
    double _lastDrawTime, _lastContentPresentation, _maxPresentationGap;
    CMTime _lastContentStamp;
    unsigned _capturePhase;
    double _lastCapturePTS, _lastSelectedPTS;
    NSUInteger _slowGaps;
    NSUInteger _presentedMids, _selected, _generated, _overruns, _presented;
    NSString *_fault;
    NSMutableArray<VTFrameProcessorFrame *> *_pending;
    double _offset, _firstArrival, _firstPTS, _maxSourceGap;
    CMTime _lastLatencyStamp;
    NSMutableArray<NSNumber *> *_originalLatency;
    dispatch_semaphore_t _inflight;
}
- (id<MTLRenderPipelineState>)screenPipeline:(id<MTLLibrary>)library error:(NSError **)error {
    MTLRenderPipelineDescriptor *desc=[MTLRenderPipelineDescriptor new];
    desc.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    desc.vertexFunction=[library newFunctionWithName:@"screenVertex"];
    desc.fragmentFunction=[library newFunctionWithName:@"screenFragment"];
    if(!desc.vertexFunction || !desc.fragmentFunction) { *error=FrameError(@"缺少 Metal 显示函数"); return nil; }
    return [library.device newRenderPipelineStateWithDescriptor:desc error:error];
}
// The file watcher calls this on its serial background queue.
- (BOOL)installShader:(NSString *)source error:(NSError **)error {
    id<MTLLibrary> library=[_engine.device newLibraryWithSource:source options:nil error:error];
    if(!library) return NO;
    id<MTLRenderPipelineState> screen=[self screenPipeline:library error:error];
    if(!screen) return NO;
    MetalEngine *motion=[[MetalEngine alloc] initWithLibrary:library error:error];
    if(!motion) return NO;
    MetalEngine *predictor=[[MetalEngine alloc] initWithLibrary:library error:error];
    if(!predictor) return NO;
    dispatch_sync(_nativeQueue,^{
        [self->_native installPredictor:predictor];
        @synchronized(self) {
            self->_updatedMotion=motion;
            self->_pipeline=screen;
        }
    });
    return YES;
}
- (instancetype)initWithError:(NSError **)error {
    if (!(self=[super init])) return nil;
    _engine=[[MetalEngine alloc] initWithError:error];
    if(!_engine) return nil;
    NSNumber *bufferMS=[NSBundle.mainBundle objectForInfoDictionaryKey:@"FrameBridgeDetailBufferMS"];
    _detailBufferSeconds=bufferMS ? bufferMS.doubleValue/1000 : 0.040;
    _originalLatency=[NSMutableArray array];
    _pending=[NSMutableArray array];
    _inflight=dispatch_semaphore_create(2);
    _view=[[MTKView alloc] initWithFrame:NSZeroRect device:_engine.device];
    ((CAMetalLayer *)_view.layer).maximumDrawableCount=2;
    _view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    _view.colorspace=space; CGColorSpaceRelease(space);
    _view.preferredFramesPerSecond=120; _view.clearColor=MTLClearColorMake(0,0,0,1);
    _pipeline=[self screenPipeline:_engine.library error:error];
    if(!_pipeline) return nil;
    _view.delegate=self;
    _nativeQueue=dispatch_queue_create("FrameBridge.native-interpolation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    _metalQueue=dispatch_queue_create("FrameBridge.metal-interpolation",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    dispatch_async(_nativeQueue,^{ @autoreleasepool {
        NSError *nativeError=nil;
        NativeMotion *model=[[NativeMotion alloc] initWithWidth:1920 height:1080 modelWidth:1280 modelHeight:720 error:&nativeError];
        VTFrameProcessorFrame *a=TestFrame(1920,1080,0), *b=TestFrame(1920,1080,1);
        if(model && a && b && [model guidedMidpointFrom:a to:b error:&nativeError]) {
            @synchronized(self) { self->_native=model; }
        } else NSLog(@"Apple interpolation unavailable: %@",nativeError);
    }});
    return self;
}
// Called on the serial capture queue. The render queue only accesses the
// presentation timeline while holding the same short lock.
- (void)setNativeOutput:(BOOL)nativeOutput {
    if(_nativeOutput==nativeOutput) return;
    [self reset];
    _nativeOutput=nativeOutput;
}
- (void)reset {
    _capturePhase=0;
    _previous=nil; _maxSourceGap=0; _selected=0; _fault=nil;
    @synchronized(self) { [_pending removeAllObjects]; [_originalLatency removeAllObjects]; _lastLatencyStamp=kCMTimeInvalid; _displayed=nil; _lastContentPresentation=_maxPresentationGap=0; _lastContentStamp=kCMTimeInvalid; _epoch++; _slowGaps=_missedSlots=_longPairs=0; _presentedMids=_presented=_overruns=_generated=0; }
}
// Queue the source immediately so it can be displayed if the midpoint arrives late.
- (BOOL)submitNativeFrom:(VTFrameProcessorFrame *)left to:(VTFrameProcessorFrame *)right {
    NSUInteger epoch;
    NativeMotion *model;
    @synchronized(self) {
        if(!_native || _nativeBusy) return NO;
        model=_native; epoch=_epoch; _nativeBusy=YES;
        [_pending addObject:right];
        while(_pending.count>6) { [_pending removeObjectAtIndex:0]; _overruns++; }
    }
    dispatch_async(_nativeQueue,^{ @autoreleasepool {
        NSError *error=nil;
        VTFrameProcessorFrame *mid=[model guidedMidpointFrom:left to:right error:&error];
        @synchronized(self) {
            self->_nativeBusy=NO;
            if(epoch!=self->_epoch) return;
            if(!mid) {self->_native=nil; NSLog(@"Apple interpolation stopped: %@",error); return;}
            if(self->_displayed && CMTimeCompare(mid.presentationTimeStamp,self->_displayed.presentationTimeStamp)<=0) {
                self->_overruns++; return;
            }
            NSUInteger at=[self->_pending indexOfObjectIdenticalTo:right];
            if(at==NSNotFound) { self->_overruns++; return; }
            [self->_pending insertObject:mid atIndex:at];
            self->_generated++;
        }
    }});
    return YES;
}
// The capture callback always queues the original. Compute only phases that
// still have presentation time available, with at most one Metal job in flight.
- (void)submitMetalFrom:(VTFrameProcessorFrame *)left to:(VTFrameProcessorFrame *)right count:(int)count {
    NSUInteger epoch;
    double offset;
    MetalEngine *engine;
    @synchronized(self) {
        if (_metalBusy) { _missedSlots+=count; return; }
        _metalBusy=YES;
        epoch=_epoch;
        offset=_offset;
        engine=_updatedMotion ?: _engine;
    }
    dispatch_async(_metalQueue, ^{ @autoreleasepool {
        double start=CMTimeGetSeconds(left.presentationTimeStamp);
        double step=CMTimeGetSeconds(CMTimeSubtract(right.presentationTimeStamp,left.presentationTimeStamp))/(count+1);
        double due=CACurrentMediaTime()-offset;
        int first=1;
        while(first<=count && start+first*step<=due) first++;
        NSError *error=nil;
        NSArray *frames=first<=count ? [engine between:left and:right count:count startingAt:first error:&error] : nil;
        @synchronized(self) {
            self->_metalBusy=NO;
            if(epoch!=self->_epoch) return;
            NSUInteger at=[self->_pending indexOfObjectIdenticalTo:right];
            NSUInteger inserted=0;
            if(at!=NSNotFound) for(VTFrameProcessorFrame *mid in frames) {
                if(self->_displayed && CMTimeCompare(mid.presentationTimeStamp,self->_displayed.presentationTimeStamp)<=0) continue;
                [self->_pending insertObject:mid atIndex:at++];
                inserted++;
            }
            self->_generated+=inserted;
            self->_missedSlots+=count-inserted;
            if(error) NSLog(@"Metal interpolation failed: %@",error);
        }
    }});
}
- (VTFrameProcessorFrame *)sourceFrame:(CVPixelBufferRef)pb pts:(CMTime)pts arrival:(double)arrival {
    VTFrameProcessorFrame *frame=[[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:pts];
    if(frame) objc_setAssociatedObject(frame,&captureArrivalKey,@(arrival),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else _fault=@"采集缓冲缺少 IOSurface";
    return frame;
}
- (void)accept:(CVPixelBufferRef)pb pts:(CMTime)pts {
    if(!pb || CVPixelBufferGetPixelFormatType(pb)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || !CMTIME_IS_NUMERIC(pts)) return;
    double stamp=CMTimeGetSeconds(pts), now=CACurrentMediaTime();
    if(_nativeOutput) {
        VTFrameProcessorFrame *latest=[self sourceFrame:pb pts:pts arrival:now];
        if(latest) @synchronized(self) { _displayed=latest; }
        return;
    }
    int w=(int)CVPixelBufferGetWidth(pb), h=(int)CVPixelBufferGetHeight(pb);
    double sampleGap=stamp-_lastCapturePTS;
    if(_previous && (CVPixelBufferGetWidth(_previous.buffer)!=w || CVPixelBufferGetHeight(_previous.buffer)!=h ||
        sampleGap<0 || sampleGap>0.1 || fabs((now-_firstArrival)-(stamp-_firstPTS))>0.12)) [self reset];
    BOOL first=(!_previous);
    if(first) {
        _firstArrival=now; _firstPTS=stamp;
        _capturePhase=0;
    } else {
        if(sampleGap==0) return;
        unsigned ticks=(unsigned)MAX(1L,lround(sampleGap*60));
        _capturePhase=(_capturePhase+ticks)%2;
    }
    _lastCapturePTS=stamp;
    if(_capturePhase) return;
    double dt=first ? 0 : stamp-_lastSelectedPTS;
    BOOL adjacent=!first && dt>0.023 && dt<0.045;
    CMTime scheduled=pts;
    if(adjacent) {
        // Stabilize consecutive 30 Hz timestamps while following 59.94 Hz inputs.
        double predicted=CMTimeGetSeconds(_previous.presentationTimeStamp)+1.0/30;
        double error=stamp-predicted;
        if(fabs(error)<0.006) scheduled=CMTimeMakeWithSeconds(predicted+error*0.125,1000000);
    }
    VTFrameProcessorFrame *frame=[self sourceFrame:pb pts:scheduled arrival:now];
    if(!frame) return;
    _lastSelectedPTS=stamp; _selected++;
    _maxSourceGap=MAX(_maxSourceGap,dt);
    if(!first && !adjacent) _longPairs++;
    @synchronized(self) {
        double desired=now-stamp+self.detailBufferSeconds;
        if(first) _offset=desired;
        else if(fabs(desired-_offset)>0.003)
            _offset+=fmax(-0.0003,fmin(0.0003,desired-_offset));
    }
    if(adjacent && w==1920 && h==1080 && [self submitNativeFrom:_previous to:frame]) {
        _previous=frame;
        return;
    }
    @synchronized(self) {
        [_pending addObject:frame];
        while(_pending.count>6) {[_pending removeObjectAtIndex:0]; _overruns++;}
    }
    if(adjacent) [self submitMetalFrom:_previous to:frame count:1];
    _previous=frame;
}
- (NSString *)ratesForInterval:(double)t {
    return [self ratesForInterval:t captureFPS:0 drops:0];
}
- (NSString *)ratesForInterval:(double)t captureFPS:(double)captureFPS drops:(NSUInteger)drops {
    NSString *rates=nil;
    @synchronized(self) {
        if(_nativeOutput) rates=[NSString stringWithFormat:@"原生输出 · 显示 %.0f",_presented/t];
        else rates=[NSString stringWithFormat:@"固定 30→60 · 选取 %.0f + 补 %.0f · 显示 %.0f · 上屏补帧 %.0f · 跳过 %lu",
               _selected/t,_generated/t,_presented/t,_presentedMids/t,(unsigned long)_overruns];
        double latency=0;
        if(_originalLatency.count) {
            [_originalLatency sortUsingSelector:@selector(compare:)];
            latency=_originalLatency[(_originalLatency.count-1)/2].doubleValue;
            rates=[rates stringByAppendingFormat:@" · 软件 %.0f ms",latency];
            [_originalLatency removeAllObjects];
        }
        if(_longPairs || _missedSlots)
            rates=[rates stringByAppendingFormat:@" · 输入断档 %lu / 未补 %lu",(unsigned long)_longPairs,(unsigned long)_missedSlots];
        rates=[rates stringByAppendingFormat:@" · 最长换帧 %.1f ms / 原帧 %.1f ms · 慢间隔 %lu",
               _maxPresentationGap*1000,_maxSourceGap*1000,(unsigned long)_slowGaps];
        _slowGaps=0;
        _maxPresentationGap=_maxSourceGap=0;
        _longPairs=_missedSlots=0;
        _generated=0; _presentedMids=_presented=_overruns=0;
    }
    _selected=0;
    return _fault ?: rates;
}
// Caller holds the timeline lock. Selection is read-only until a drawable
// and render encoder are available. A missed drawable can retry the same PTS.
- (VTFrameProcessorFrame *)frameDueAt:(double)due {
    NSUInteger index=0;
    while(index+1<_pending.count && CMTimeGetSeconds(_pending[index+1].presentationTimeStamp)<due-0.014)
        index++;
    if(index>=_pending.count) return _displayed;
    VTFrameProcessorFrame *next=_pending[index];
    double pts=CMTimeGetSeconds(next.presentationTimeStamp);
    BOOL gap=_displayed && pts-CMTimeGetSeconds(_displayed.presentationTimeStamp)>0.024;
    // When a midpoint is outstanding, leave its slot open until close to due.
    return pts<=due+(gap ? 0.004 : 0.008) ? next : _displayed;
}
- (BOOL)consumeFrame:(VTFrameProcessorFrame *)frame {
    if(frame==_displayed) return YES;
    NSUInteger i=[_pending indexOfObjectIdenticalTo:frame];
    if(i==NSNotFound) return NO;
    [_pending removeObjectsInRange:NSMakeRange(0,i+1)];
    _overruns+=i;
    _displayed=frame;
    return YES;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
- (void)drawInMTKView:(MTKView *)view {
    if(dispatch_semaphore_wait(_inflight,DISPATCH_TIME_NOW)) return;
    VTFrameProcessorFrame *frame=nil;
    id<MTLRenderPipelineState> pipeline;
    double target=0;
    BOOL paced=NO;
    NSUInteger epoch;
    @synchronized(self) {
        pipeline=_pipeline;
        double due=CACurrentMediaTime()-_offset;
        frame=[self frameDueAt:due];
        if(frame && frame!=_displayed) {
            target=_offset+CMTimeGetSeconds(frame.presentationTimeStamp);
            if(_lastDrawn) {
                double step=CMTimeGetSeconds(CMTimeSubtract(frame.presentationTimeStamp,_lastDrawn.presentationTimeStamp));
                paced=step>=0.013 && step<=0.020 && _offset+due-target<0.006;
            }
        }
        epoch=_epoch;
    }
    if(!frame) {dispatch_semaphore_signal(_inflight);return;}
    // Sample the timeline at display cadence. Acquire a drawable only when
    // content changes, on resize, or to refresh a long-held surface.
    CGSize size=view.drawableSize;
    double now=CACurrentMediaTime();
    if(frame==_lastDrawn && CGSizeEqualToSize(size,_lastDrawSize) && now-_lastDrawTime<1) {
        dispatch_semaphore_signal(_inflight); return;
    }
    id<CAMetalDrawable> drawable=view.currentDrawable;
    MTLRenderPassDescriptor *pass=view.currentRenderPassDescriptor;
    if(!drawable || !pass) {dispatch_semaphore_signal(_inflight);return;}
    CVMetalTextureRef y=[_engine plane:0 of:frame.buffer], uv=[_engine plane:1 of:frame.buffer];
    if(!y || !uv) {if(y) CFRelease(y); if(uv) CFRelease(uv);dispatch_semaphore_signal(_inflight);return;}
    id<MTLCommandBuffer> cmd=[_engine.commands commandBuffer];
    id<MTLRenderCommandEncoder> enc=[cmd renderCommandEncoderWithDescriptor:pass];
    if(!enc) {CFRelease(y); CFRelease(uv); dispatch_semaphore_signal(_inflight);return;}
    @synchronized(self) {
        if(epoch!=_epoch || ![self consumeFrame:frame]) {
            [enc endEncoding]; CFRelease(y); CFRelease(uv); dispatch_semaphore_signal(_inflight);return;
        }
    }
    double w=CVPixelBufferGetWidth(frame.buffer), h=CVPixelBufferGetHeight(frame.buffer);
    double scale=MIN(drawable.texture.width/w,drawable.texture.height/h);
    [enc setViewport:(MTLViewport){(drawable.texture.width-w*scale)/2,(drawable.texture.height-h*scale)/2,w*scale,h*scale,0,1}];
    CFTypeRef matrix=CVBufferCopyAttachment(frame.buffer,kCVImageBufferYCbCrMatrixKey,NULL);
    simd_float2 factors={0.2126,0.0722};
    if(matrix) {
        if(CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4)) factors=(simd_float2){0.299,0.114};
        if(CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_2020)) factors=(simd_float2){0.2627,0.0593};
        CFRelease(matrix);
    }
    [enc setRenderPipelineState:pipeline];
    [enc setFragmentTexture:CVMetalTextureGetTexture(y) atIndex:0];
    [enc setFragmentTexture:CVMetalTextureGetTexture(uv) atIndex:1];
    [enc setFragmentBytes:&factors length:sizeof(factors) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding];
    CMTime stamp=frame.presentationTimeStamp;
    double arrival=[objc_getAssociatedObject(frame,&captureArrivalKey) doubleValue];
    [drawable addPresentedHandler:^(id<MTLDrawable> d){
        double presented=d.presentedTime;
        if(presented<=0) return;
        @synchronized(self) {
            if(epoch!=self->_epoch) return;
            if(self->_lastContentPresentation>0 &&
               (presented<=self->_lastContentPresentation || CMTimeCompare(stamp,self->_lastContentStamp)==0)) return;
            if(self->_lastContentPresentation>0) {
                double gap=presented-self->_lastContentPresentation;
                self->_maxPresentationGap=MAX(self->_maxPresentationGap,gap);
                if(gap>0.022) self->_slowGaps++;
            }
            self->_lastContentPresentation=presented;
            self->_lastContentStamp=stamp;
            self->_presented++;
            if(arrival==0) self->_presentedMids++;
            if(arrival>0 && (!CMTIME_IS_VALID(self->_lastLatencyStamp) || CMTimeCompare(stamp,self->_lastLatencyStamp)>0)) {
                self->_lastLatencyStamp=stamp;
                if(self->_originalLatency.count<256) [self->_originalLatency addObject:@((presented-arrival)*1000)];
            }
        }
        if(self->_presentationObserver) self->_presentationObserver(stamp,presented);
    }];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> c){(void)frame.buffer; CFRelease(y);CFRelease(uv);dispatch_semaphore_signal(self->_inflight);}];
    if(paced) [cmd presentDrawable:drawable afterMinimumDuration:0.013];
    else if(target>CACurrentMediaTime()) [cmd presentDrawable:drawable atTime:target];
    else [cmd presentDrawable:drawable];
    [cmd commit];
    _lastDrawn=frame; _lastDrawSize=size; _lastDrawTime=now;
}
@end
