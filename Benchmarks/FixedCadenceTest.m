#import "Player.h"
#import <QuartzCore/QuartzCore.h>
#import <assert.h>
#import <unistd.h>

// A CPU-only midpoint producer keeps the test on the actual capture and queue paths.
@interface StubMidpoints : NSObject
@end
@implementation StubMidpoints
- (NSArray *)between:(VTFrameProcessorFrame *)a and:(VTFrameProcessorFrame *)b count:(int)n startingAt:(int)first error:(NSError **)error {
    NSMutableArray *frames=[NSMutableArray array];
    for(int i=first;i<=n;i++) {
        CMTime dt=CMTimeSubtract(b.presentationTimeStamp,a.presentationTimeStamp);
        CMTime pts=CMTimeAdd(a.presentationTimeStamp,CMTimeMultiplyByRatio(dt,i,n+1));
        [frames addObject:[[VTFrameProcessorFrame alloc] initWithBuffer:b.buffer presentationTimeStamp:pts]];
    }
    return frames;
}
@end

int main(void) { @autoreleasepool {
    Player *player=[Player new];
    NSMutableArray *queue=[NSMutableArray array];
    dispatch_queue_t jobs=dispatch_queue_create("test.cadence",DISPATCH_QUEUE_SERIAL);
    [player setValue:queue forKey:@"pending"];
    [player setValue:jobs forKey:@"metalQueue"];
    [player setValue:[StubMidpoints new] forKey:@"engine"];
    player.detailBufferSeconds=.038;
    VTFrameProcessorFrame *a=TestFrame(96,64,0), *b=TestFrame(96,64,1);
    int level=80;
    for(VTFrameProcessorFrame *f in @[a,b]) {
        CVPixelBufferLockBaseAddress(f.buffer,0);
        memset(CVPixelBufferGetBaseAddressOfPlane(f.buffer,0),level,CVPixelBufferGetBytesPerRowOfPlane(f.buffer,0)*64);
        CVPixelBufferUnlockBaseAddress(f.buffer,0); level+=10;
    }
    double start=CACurrentMediaTime();
    int distinct=0;
    unsigned originals=0,mids=0;
    for(int tick=0;tick<121;tick++) {
        if(tick==75) continue; // Missing odd input must preserve the sampling phase.
        double wait=start+tick*1001.0/60000-CACurrentMediaTime();
        if(wait>0) usleep((useconds_t)(wait*1e6));
        if(tick<40 || (tick<80 && tick%2==0)) distinct++;
        CVPixelBufferRef pb=distinct%2 ? b.buffer : a.buffer;
        [player accept:pb pts:CMTimeMake(tick*1001,60000)];
        dispatch_sync(jobs,^{});
        if(tick%2) { assert(queue.count==0); continue; }
        assert(queue.count==(tick ? 2 : 1));
        VTFrameProcessorFrame *right=queue.lastObject;
        assert(right.buffer==pb);
        if(tick) {
            assert(fabs(CMTimeGetSeconds(CMTimeSubtract(right.presentationTimeStamp,[queue[0] presentationTimeStamp]))-1.0/60)<0.001);
            mids++;
        }
        originals++;
        [queue removeAllObjects];
    }
    assert(originals==61 && mids==60);
    assert([[player ratesForInterval:2] containsString:@"固定 30→60"]);
    [player accept:a.buffer pts:CMTimeMake(123*1001,60000)];
    [player accept:b.buffer pts:CMTimeMake(124*1001,60000)];
    dispatch_sync(jobs,^{});
    assert(queue.count==1); // Never interpolate through a missing source slot.
    player.nativeOutput=YES;
    assert(queue.count==0);
    [player accept:a.buffer pts:CMTimeMake(125*1001,60000)];
    assert(((VTFrameProcessorFrame *)[player valueForKey:@"displayed"]).buffer==a.buffer);
    puts("PASS fixed 30->60 on changing 60Hz, repeated 30Hz, static content, missing capture and manual native output");
}}
