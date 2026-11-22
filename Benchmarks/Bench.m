#import "Player.h"
#import "NativeMotion.h"
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

enum { width=1920, height=1080, period=60 };
static const size_t frameBytes=(size_t)width*height*3/2;

// One 60 Hz reference cycle with a panning background, thin poles, a moving
// foreground occluder and fixed HUD. The triangular pan reverses continuously.
static uint8_t scenePixel(int x,int y,int tick) {
    int phase=MIN(tick,period-tick);
    int u=x+phase*8, v=y+phase;
    int value=52+((u/91+v/73)%2)*32+((u*3+v*5)%47);
    if(u%117<3) value=204;
    if(v%67<2) value=66;
    int local=x-(520+phase*19);
    if(local>=0 && local<280 && y>450 && y<622)
        value=94+((local/8+y/8)%2)*48;
    if(y>=40 && y<55 && x>=60 && x<220) value=(x%11<3)?230:44;
    return value;
}

static VTFrameProcessorFrame *source(int index, NSData *clip) {
    CVPixelBufferRef pb=NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&pb)) return nil;
    CVPixelBufferLockBaseAddress(pb,0);
    const uint8_t *raw=clip ? (const uint8_t *)clip.bytes+index*frameBytes : NULL;
    for(int plane=0;plane<2;plane++) {
        uint8_t *row=CVPixelBufferGetBaseAddressOfPlane(pb,plane);
        size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pb,plane);
        for(int y=0;y<(plane?height/2:height);y++,row+=stride) {
            if(raw) memcpy(row,raw+(plane*height+y)*width,width);
            else if(plane) memset(row,128,width);
            else for(int x=0;x<width;x++) row[x]=scenePixel(x,y,index%period);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb,0);
    VTFrameProcessorFrame *frame=[[VTFrameProcessorFrame alloc] initWithBuffer:pb presentationTimeStamp:CMTimeMake(index,60)];
    CVPixelBufferRelease(pb);
    return frame;
}

static double percentile(NSArray<NSNumber *> *values,double q) {
    NSArray *sorted=[values sortedArrayUsingSelector:@selector(compare:)];
    return sorted.count ? [sorted[(NSUInteger)ceil(sorted.count*q)-1] doubleValue] : 0;
}
static void report(NSDictionary *metrics) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:metrics options:NSJSONWritingSortedKeys error:NULL];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}

static int quality(NSData *clip) {
    NSError *error=nil;
    NativeMotion *model=[[NativeMotion alloc] initWithWidth:width height:height modelWidth:1280 modelHeight:720 error:&error];
    int count=clip ? (int)(clip.length/frameBytes) : period+1;
    // A 60 Hz capture of a 30 fps game typically repeats each game frame twice.
    int step=clip ? 2 : 1;
    NSMutableArray *times=[NSMutableArray array];
    double edgeError=0, detailError=0, totalError=0;
    NSUInteger edges=0, pixels=0, severe=0;
    VTFrameProcessorFrame *left=source(0,clip);
    for(int i=0;i+2*step<count;i+=2*step) { @autoreleasepool {
        VTFrameProcessorFrame *truth=source(i+step,clip), *right=source(i+2*step,clip);
        if(!model || !left || !right || !truth) { NSLog(@"Fixture or model unavailable: %@",error); return 1; }
        double start=CACurrentMediaTime();
        VTFrameProcessorFrame *mid=[model guidedMidpointFrom:left to:right error:&error];
        if(!mid || CMTimeCompare(mid.presentationTimeStamp,truth.presentationTimeStamp)) { NSLog(@"Midpoint failed: %@",error); return 1; }
        if(i>=4*step) [times addObject:@((CACurrentMediaTime()-start)*1000)];
        CVPixelBufferRef buffers[]={mid.buffer,truth.buffer};
        const uint8_t *lines[2]; size_t strides[2];
        for(int k=0;k<2;k++) {
            CVPixelBufferLockBaseAddress(buffers[k],kCVPixelBufferLock_ReadOnly);
            lines[k]=CVPixelBufferGetBaseAddressOfPlane(buffers[k],0);
            strides[k]=CVPixelBufferGetBytesPerRowOfPlane(buffers[k],0);
        }
        for(int y=8;y<height-8;y+=2) for(int x=8;x<width-8;x+=2) {
            const uint8_t *p=lines[0]+y*strides[0]+x,*t=lines[1]+y*strides[1]+x;
            int delta=abs(*p-*t); totalError+=delta; pixels++;
            int gx=t[1]-t[-1], gy=t[strides[1]]-*(t-strides[1]);
            if(abs(gx)+abs(gy)<32) continue;
            edgeError+=delta; severe+=delta>=24; edges++;
            detailError+=abs((p[1]-p[-1])-gx)+abs((p[strides[0]]-*(p-strides[0]))-gy);
        }
        for(int k=0;k<2;k++) CVPixelBufferUnlockBaseAddress(buffers[k],kCVPixelBufferLock_ReadOnly);
        left=right;
    }}
    if(!edges || !times.count) return 1;
    report(@{@"pairs":@(times.count+2),@"mae":@(totalError/pixels),@"edge_mae":@(edgeError/edges),
             @"edge_gradient_error":@(detailError/edges),@"bad_edge_pct":@(100.0*severe/edges),
             @"compute_p50_ms":@(percentile(times,.5)),@"compute_p95_ms":@(percentile(times,.95))});
    return 0;
}

static int playback(double bufferMS,int seconds) {
    NSApplication *app=NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSError *error=nil;
    Player *player=[[Player alloc] initWithError:&error];
    if(!player) { NSLog(@"%@",error); return 1; }
    player.detailBufferSeconds=bufferMS/1000;
    enum { warmup=120 };
    int end=warmup+seconds*60;
    NSMutableArray *frames=[NSMutableArray array],*events=[NSMutableArray array];
    NSMutableData *inputTimes=[NSMutableData dataWithLength:sizeof(double)*(end+8)];
    for(int i=0;i<period;i+=2) {
        VTFrameProcessorFrame *f=source(i,nil);
        if(!f) return 1;
        [frames addObject:f];
    }
    player.presentationObserver=^(CMTime stamp,double presented) {
        int tick=(int)CMTimeConvertScale(stamp,60,kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        if(tick>=warmup && tick<end) @synchronized(events){ [events addObject:@[@(tick),@(presented)]]; }
    };
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,960,540) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.ignoresMouseEvents=YES; window.contentView=player.view; [window orderBack:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
        double *arrivals=inputTimes.mutableBytes;
        double start=CACurrentMediaTime();
        for(int i=0;i<end+8;i++) { @autoreleasepool {
            VTFrameProcessorFrame *frame=frames[(i%period)/2];
            double wait=start+i/60.0-CACurrentMediaTime();
            if(wait>0) usleep((useconds_t)(wait*1000000));
            arrivals[i]=CACurrentMediaTime();
            [player accept:frame.buffer pts:CMTimeMake(i,60)];
        }}
        dispatch_async(dispatch_get_main_queue(),^{[app stop:nil]; [app postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];});
    });
    [app run];
    NSMutableDictionary *first=[NSMutableDictionary dictionary];
    @synchronized(events) {
        for(NSArray *event in events) {
            NSNumber *tick=event[0], *time=event[1];
            if(!first[tick] || [time compare:first[tick]]==NSOrderedAscending) first[tick]=time;
        }
    }
    NSMutableArray *latency=[NSMutableArray array];
    int generated=0;
    const double *arrivals=inputTimes.bytes;
    for(NSNumber *tick in first) {
        int i=tick.intValue;
        if(i%2) generated++;
        else [latency addObject:@(([first[tick] doubleValue]-arrivals[i])*1000)];
    }
    if(!latency.count) { fprintf(stderr,"No original frames presented. Keep the display awake.\n"); return 1; }
    report(@{@"buffer_ms":@(bufferMS),@"original_fps":@(latency.count/(double)seconds),
             @"generated_fps":@(generated/(double)seconds),@"unique_fps":@(first.count/(double)seconds),
             @"original_p50_ms":@(percentile(latency,.5)),@"original_p95_ms":@(percentile(latency,.95))});
    return 0;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"quality")) return quality(nil);
    if(argc==3 && !strcmp(argv[1],"quality")) {
        NSData *clip=[NSData dataWithContentsOfFile:@(argv[2]) options:NSDataReadingMappedIfSafe error:NULL];
        if(clip.length<13*frameBytes || clip.length%frameBytes) return 2;
        return quality(clip);
    }
    if(argc==4 && !strcmp(argv[1],"playback")) {
        double ms=atof(argv[2]); int s=atoi(argv[3]);
        if(isfinite(ms) && ms>=16 && ms<=100 && s>=3 && s<=120) return playback(ms,s);
    }
    fprintf(stderr,"usage: Bench quality [1080p60.nv12] | playback BUFFER_MS SECONDS\n"); return 2;
}}
