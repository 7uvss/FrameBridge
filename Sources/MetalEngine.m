#import "MetalEngine.h"
@implementation MetalEngine {
    CVMetalTextureCacheRef _cache;
    id<MTLComputePipelineState> _reduce, _largeMotion, _wideMotion, _dominantMotion, _estimate, _resolve, _resolveDonor, _synthesize, _detail, _estimateCamera, _scoreCamera, _scoreBands, _selectBand, _refineBands;
    id<MTLTexture> _smallA, _smallB, _tinyA, _tinyB, _seed, _field, _wide, _dominant, _guidance, _previousField, _camera, _cameraScores, _bandScores, _bandSeeds, _bands;
    __weak VTFrameProcessorFrame *_lastSource;
    double _lastInterval;
    CVPixelBufferPoolRef _pool;
    int _width, _height;
}
- (instancetype)initWithError:(NSError **)error {
    NSURL *url=[NSBundle.mainBundle URLForResource:@"Pipeline" withExtension:@"metal"];
    if(!url) { *error=FrameError(@"未找到 Metal 着色器文件"); return nil; }
    NSString *source=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:error];
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLLibrary> library=source ? [device newLibraryWithSource:source options:nil error:error] : nil;
    return library ? [self initWithLibrary:library error:error] : nil;
}
- (instancetype)initWithLibrary:(id<MTLLibrary>)library error:(NSError **)error {
    if (!(self=[super init])) return nil;
    _device=library.device;
    _library=library;
    _commands=[_device newCommandQueue];
    if (!_commands || CVMetalTextureCacheCreate(NULL,NULL,_device,NULL,&_cache)) {
        *error=FrameError(@"无法创建 Metal 管线"); return nil;
    }
    _reduce=[self compute:@"reduceLuma" error:error];
    if (!_reduce) return nil;
    _largeMotion=[self compute:@"largeDisplacement" error:error];
    if (!_largeMotion) return nil;
    _wideMotion=[self compute:@"wideMotion" error:error];
    if (!_wideMotion) return nil;
    _dominantMotion=[self compute:@"dominantMotion" error:error];
    if (!_dominantMotion) return nil;
    _resolve=[self compute:@"resolveMotion" error:error];
    if (!_resolve) return nil;
    _resolveDonor=[self compute:@"resolveDonor" error:error];
    if(!_resolveDonor) return nil;
    _estimate=[self compute:@"estimate" error:error];
    if (!_estimate) return nil;
    _synthesize=[self compute:@"synthesize" error:error];
    if(!_synthesize) return nil;
    _refineBands=[self compute:@"refineBandsParallel" error:error];
    if(!_refineBands) return nil;
    _scoreBands=[self compute:@"scoreBandsParallel" error:error];
    if(!_scoreBands) return nil;
    _selectBand=[self compute:@"selectBand" error:error];
    if(!_selectBand) return nil;
    _scoreCamera=[self compute:@"scoreCameraParallel" error:error];
    if(!_scoreCamera) return nil;
    _estimateCamera=[self compute:@"estimateCamera" error:error];
    if(!_estimateCamera) return nil;
    _detail=[self compute:@"restoreDetail" error:error];
    return _detail ? self : nil;
}
- (id<MTLComputePipelineState>)compute:(NSString *)name error:(NSError **)error {
    id<MTLFunction> fn=[_library newFunctionWithName:name];
    if(fn.functionType!=MTLFunctionTypeKernel) {
        *error=FrameError([@"缺少 Metal 计算函数 " stringByAppendingString:name]); return nil;
    }
    return [_device newComputePipelineStateWithFunction:fn error:error];
}
- (CVMetalTextureRef)plane:(int)plane of:(CVPixelBufferRef)pb {
    CVMetalTextureRef tex=NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL,_cache,pb,NULL,plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
      CVPixelBufferGetWidthOfPlane(pb,plane),CVPixelBufferGetHeightOfPlane(pb,plane),plane,&tex);
    return tex;
}
- (id<MTLTexture>)texture:(MTLPixelFormat)format width:(int)w height:(int)h {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite; d.storageMode=MTLStorageModePrivate;
    return [_device newTextureWithDescriptor:d];
}
- (BOOL)prepare:(int)w height:(int)h lumaOnly:(BOOL)lumaOnly {
    MTLPixelFormat format=lumaOnly ? MTLPixelFormatR16Float : MTLPixelFormatRGBA16Float;
    if (_width==w && _height==h && _pool && _guidance.pixelFormat==format) return YES;
    if (_pool) {CVPixelBufferPoolRelease(_pool); _pool=NULL;}
    _smallA=[self texture:MTLPixelFormatR8Unorm width:(w+3)/4 height:(h+3)/4];
    _smallB=[self texture:MTLPixelFormatR8Unorm width:(w+3)/4 height:(h+3)/4];
    _field=[self texture:MTLPixelFormatRG16Float width:(w+15)/16 height:(h+15)/16];
    _tinyA=[self texture:MTLPixelFormatR8Unorm width:(w+15)/16 height:(h+15)/16];
    _tinyB=[self texture:MTLPixelFormatR8Unorm width:(w+15)/16 height:(h+15)/16];
    _seed=[self texture:MTLPixelFormatRG16Float width:(w+127)/128 height:(h+127)/128];
    _wide=[self texture:MTLPixelFormatRG16Float width:(w+63)/64 height:(h+63)/64];
    _dominant=[self texture:MTLPixelFormatRG16Float width:(w+63)/64 height:(h+63)/64];
    _previousField=[self texture:MTLPixelFormatRG16Float width:(w+15)/16 height:(h+15)/16];
    _bandScores=[self texture:MTLPixelFormatRGBA32Float width:128 height:(h+63)/64];
    _bandSeeds=[self texture:MTLPixelFormatRGBA16Float width:1 height:(h+63)/64];
    _bands=[self texture:MTLPixelFormatRGBA16Float width:1 height:(h+63)/64];
    _cameraScores=[self texture:MTLPixelFormatRGBA32Float width:(w+63)/64 height:(h+63)/64];
    _camera=[self texture:MTLPixelFormatRGBA16Float width:1 height:1];
    _guidance=[self texture:format width:w height:h];
    _lastSource=nil;
    NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@(w),(id)kCVPixelBufferHeightKey:@(h),
      (id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES,
      (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    _width=w; _height=h;
    return _bandSeeds && _bands && _bandScores && _cameraScores && _camera && _tinyA && _tinyB && _seed && _dominant && _previousField && _wide && _guidance && _field && _smallA && _smallB && !CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&_pool);
}
static void pass(id<MTLCommandBuffer> cmd,id<MTLComputePipelineState> pipeline,
                 NSArray<id<MTLTexture>> *textures,float scale,float phase) {
    id<MTLComputeCommandEncoder> enc=[cmd computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    for (NSUInteger i=0;i<textures.count;i++) [enc setTexture:textures[i] atIndex:i];
    [enc setBytes:&scale length:sizeof(scale) atIndex:0];
    [enc setBytes:&phase length:sizeof(phase) atIndex:1];
    id<MTLTexture> dst=textures.lastObject;
    [enc dispatchThreads:MTLSizeMake(dst.width,dst.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [enc endEncoding];
}
// Each SIMD group evaluates one translation across its sample patch.
static void scoreTranslations(id<MTLCommandBuffer> cmd,id<MTLComputePipelineState> pipeline,
                              NSArray<id<MTLTexture>> *textures) {
    id<MTLComputeCommandEncoder> enc=[cmd computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    for(NSUInteger i=0;i<textures.count;i++) [enc setTexture:textures[i] atIndex:i];
    id<MTLTexture> scores=textures.lastObject;
    [enc dispatchThreadgroups:MTLSizeMake(scores.width,scores.height,1)
        threadsPerThreadgroup:MTLSizeMake(pipeline.threadExecutionWidth,1,1)];
    [enc endEncoding];
}
- (VTFrameProcessorFrame *)midpointFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error {
    return [self between:a and:b count:1 error:error].firstObject;
}
- (NSArray<VTFrameProcessorFrame *> *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)count error:(NSError **)error {
    return [self between:a and:b count:count startingAt:1 lumaOnly:NO error:error];
}
- (NSArray<VTFrameProcessorFrame *> *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)count startingAt:(int)first error:(NSError **)error {
    return [self between:a and:b count:count startingAt:first lumaOnly:NO error:error];
}
- (VTFrameProcessorFrame *)detailDonorFrom:(VTFrameProcessorFrame *)a to:(VTFrameProcessorFrame *)b error:(NSError **)error {
    return [self between:a and:b count:1 startingAt:1 lumaOnly:YES error:error].firstObject;
}
- (NSArray<VTFrameProcessorFrame *> *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)count startingAt:(int)first lumaOnly:(BOOL)lumaOnly error:(NSError **)error {
    if (![self prepare:(int)CVPixelBufferGetWidth(b.buffer) height:(int)CVPixelBufferGetHeight(b.buffer) lumaOnly:lumaOnly]) {
        *error=FrameError(@"Metal 像素缓冲分配失败"); return nil;
    }
    NSMutableArray *frames=[NSMutableArray array], *planes=[NSMutableArray array];
    __attribute__((objc_precise_lifetime)) NSMutableArray *refs=[NSMutableArray array];
    int outputs=count-first+1;
    for(int i=0;i<outputs+2;i++) {
        CVPixelBufferRef pb=i==0 ? a.buffer : b.buffer;
        if(i>=2) {
            if(CVPixelBufferPoolCreatePixelBuffer(NULL,_pool,&pb)) { *error=FrameError(@"Metal 输出分配失败"); return nil; }
            CVBufferPropagateAttachments(b.buffer,pb);
            CMTime pts=CMTimeAdd(a.presentationTimeStamp,CMTimeMultiplyByRatio(CMTimeSubtract(b.presentationTimeStamp,a.presentationTimeStamp),first+i-2,count+1));
            VTFrameProcessorFrame *frame=[[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:pts];
            CVPixelBufferRelease(pb);
            if(!frame) { *error=FrameError(@"Metal 输出缓冲缺少 IOSurface"); return nil; }
            [frames addObject:frame]; pb=frame.buffer;
        }
        for(int p=0;p<2;p++) {
            CVMetalTextureRef ref=[self plane:p of:pb];
            if(!ref) { *error=FrameError(@"无法映射 NV12 Metal 纹理"); return nil; }
            [planes addObject:CVMetalTextureGetTexture(ref)]; [refs addObject:CFBridgingRelease(ref)];
        }
    }
    id<MTLCommandBuffer> cmd=[_commands commandBuffer];
    // The preceding right endpoint is this pair's left endpoint.
    if(_lastSource!=a) {
        pass(cmd,_reduce,@[planes[0],_smallA],0,0);
        pass(cmd,_reduce,@[_smallA,_tinyA],0,0);
    }
    pass(cmd,_reduce,@[planes[2],_smallB],0,0);
    pass(cmd,_reduce,@[_smallB,_tinyB],0,0);
    pass(cmd,_largeMotion,@[_tinyA,_tinyB,_seed],0,0);
    pass(cmd,_wideMotion,@[_smallA,_smallB,_seed,_wide],0,0);
    pass(cmd,_dominantMotion,@[_wide,_dominant],0,0);
    double interval=CMTimeGetSeconds(CMTimeSubtract(b.presentationTimeStamp,a.presentationTimeStamp));
    float ratio=0;
    if(_lastSource==a && _lastInterval>0 && interval>0 && interval<0.060) {
        double scale=interval/_lastInterval;
        if(scale>=0.55 && scale<=1.8) ratio=(float)scale;
    }
    pass(cmd,_estimate,@[_smallA,_smallB,planes[0],planes[2],_wide,_previousField,_dominant,_field],ratio,0);
    for(int i=0;i<outputs;i++) {
        float phase=(float)(first+i)/(count+1);
        if(lumaOnly) {
            pass(cmd,_resolveDonor,@[planes[0],planes[2],planes[1],planes[3],_field,_wide,_dominant,_guidance,planes[4+2*i]],1,phase);
        } else {
            pass(cmd,_resolve,@[planes[0],planes[2],planes[1],planes[3],_field,_wide,_dominant,_guidance],1,phase);
            pass(cmd,_synthesize,@[planes[0],planes[2],_guidance,planes[4+2*i]],1,phase);
            pass(cmd,_synthesize,@[planes[1],planes[3],_guidance,planes[5+2*i]],2,phase);
        }
    }
    if(lumaOnly) {
        scoreTranslations(cmd,_scoreCamera,@[planes[0],planes[2],_wide,_field,_cameraScores]);
        pass(cmd,_estimateCamera,@[_cameraScores,_camera],0,0);
        scoreTranslations(cmd,_scoreBands,@[planes[0],planes[2],_wide,_field,_camera,_bandScores]);
        pass(cmd,_selectBand,@[_bandScores,_bandSeeds],0,0);
        scoreTranslations(cmd,_refineBands,@[planes[0],planes[2],_bandSeeds,_bandScores]);
        pass(cmd,_selectBand,@[_bandScores,_bands],0,0);
    }
    [cmd commit]; [cmd waitUntilCompleted];
    if(cmd.status!=MTLCommandBufferStatusCompleted) {_lastSource=nil; *error=cmd.error ?: FrameError(@"Metal 命令执行失败"); return nil;}
    id<MTLTexture> temp=_previousField;
    _previousField=_field; _field=temp;
    temp=_smallA; _smallA=_smallB; _smallB=temp;
    temp=_tinyA; _tinyA=_tinyB; _tinyB=temp;
    _lastSource=b; _lastInterval=interval;
    return frames;
}
- (VTFrameProcessorFrame *)restoreDetailIn:(VTFrameProcessorFrame *)guide from:(VTFrameProcessorFrame *)prediction
                                  left:(VTFrameProcessorFrame *)left right:(VTFrameProcessorFrame *)right error:(NSError **)error {
    // Uses the motion estimates and confidence saved by detailDonorFrom: for this pair.
    CVPixelBufferRef dst=NULL;
    if(!_pool || CVPixelBufferGetWidth(guide.buffer)!=_width || CVPixelBufferGetHeight(guide.buffer)!=_height ||
        CVPixelBufferPoolCreatePixelBuffer(NULL,_pool,&dst)) {
        *error=FrameError(@"无法分配细节重建输出"); return nil;
    }
    CVBufferPropagateAttachments(guide.buffer,dst);
    VTFrameProcessorFrame *frame=[[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:guide.presentationTimeStamp];
    CVPixelBufferRelease(dst);
    if(!frame) { *error=FrameError(@"无法创建细节重建帧"); return nil; }
    __attribute__((objc_precise_lifetime)) NSMutableArray *refs=[NSMutableArray array];
    NSMutableArray *maps=[NSMutableArray array];
    CVPixelBufferRef buffers[]={guide.buffer,prediction.buffer,left.buffer,right.buffer,frame.buffer,guide.buffer,frame.buffer};
    const int channels[]={0,0,0,0,0,1,1};
    for(int i=0;i<7;i++){
        CVMetalTextureRef ref=[self plane:channels[i] of:buffers[i]];
        if(!ref) { *error=FrameError(@"细节重建纹理不可用"); return nil; }
        [maps addObject:CVMetalTextureGetTexture(ref)]; [refs addObject:CFBridgingRelease(ref)];
    }
    id<MTLCommandBuffer> cmd=[_commands commandBuffer];
    pass(cmd,_detail,@[maps[0],maps[1],maps[2],maps[3],_camera,_guidance,_bands,maps[4]],0,0);
    id<MTLBlitCommandEncoder> copy=[cmd blitCommandEncoder];
    [copy copyFromTexture:maps[5] toTexture:maps[6]]; [copy endEncoding];
    [cmd commit]; [cmd waitUntilCompleted];
    if(cmd.status!=MTLCommandBufferStatusCompleted) { *error=cmd.error ?: FrameError(@"细节重建失败"); return nil; }
    return frame;
}
- (void)dealloc {
    if(_cache) CFRelease(_cache);
    if(_pool) CVPixelBufferPoolRelease(_pool);
}
@end
