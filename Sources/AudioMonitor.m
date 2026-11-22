#import "AudioMonitor.h"
#import <QuartzCore/QuartzCore.h>
@interface AudioMonitor ()
@property(atomic,copy,readwrite) NSString *status;
@end
@implementation AudioMonitor {
    AVCaptureSession *_session;
    dispatch_queue_t _queue;
    double _lastMeter;
    unsigned _peak;
}
- (instancetype)init {
    if ((self=[super init])) {
        _queue=dispatch_queue_create("FrameBridge.audio",DISPATCH_QUEUE_SERIAL);
        self.status=@"等待音频";
    }
    return self;
}
- (void)start {
    AVAuthorizationStatus auth=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if(auth==AVAuthorizationStatusNotDetermined) {
        self.status=@"请允许麦克风权限以播放 HDMI 音频";
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted){ [self start]; }];
        return;
    }
    if(auth!=AVAuthorizationStatusAuthorized) { self.status=@"请在系统设置的麦克风权限中允许 FrameBridge"; return; }
    dispatch_async(_queue,^{ [self connect]; });
}
- (void)connect {
    if(_session.isRunning) return;
    AVCaptureDevice *source=nil;
    for(AVCaptureDevice *d in [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone,AVCaptureDeviceTypeExternal] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified].devices) {
        if([d.localizedName isEqualToString:@"USB3 Digital Audio"]) {source=d;break;}
    }
    if (!source) { self.status=@"未找到 USB3 Digital Audio"; return; }
    NSError *error=nil;
    AVCaptureDeviceInput *input=[AVCaptureDeviceInput deviceInputWithDevice:source error:&error];
    AVCaptureSession *session=[AVCaptureSession new];
    if (!input || ![session canAddInput:input]) {self.status=error.localizedDescription ?: @"无法接入 HDMI 音频";return;}
    [session beginConfiguration]; [session addInput:input];
    AVCaptureAudioPreviewOutput *speaker=[AVCaptureAudioPreviewOutput new];
    speaker.outputDeviceUniqueID=nil;
    speaker.volume=1.0;
    if(![session canAddOutput:speaker]) { [session commitConfiguration]; self.status=@"系统播放设备不可用";return; }
    [session addOutput:speaker];
    AVCaptureAudioDataOutput *meter=[AVCaptureAudioDataOutput new];
    meter.audioSettings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVLinearPCMBitDepthKey:@16,
                          AVLinearPCMIsFloatKey:@NO,AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleaved:@NO};
    [meter setSampleBufferDelegate:self queue:_queue];
    if([session canAddOutput:meter]) [session addOutput:meter];
    [session commitConfiguration]; _session=session;
    [session startRunning];
    self.status=session.isRunning ? @"HDMI 音频 → 系统输出" : @"HDMI 音频启动失败";
    NSLog(@"USB3 Digital Audio: %@",self.status);
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
    size_t length=0,total=0; char *bytes=NULL;
    if(!block || CMBlockBufferGetDataPointer(block,0,&length,&total,&bytes)) return;
    const int16_t *pcm=(const int16_t *)bytes;
    for(size_t i=0;i<length/2;i++) _peak=MAX(_peak,(unsigned)abs(pcm[i]));
    double now=CACurrentMediaTime();
    if(now-_lastMeter>=1) {
        self.status=_peak ? [NSString stringWithFormat:@"HDMI 音频 %.0f dBFS",20*log10(_peak/32768.0)] : @"HDMI 音频静音";
        static int reports=0; if(reports<3 || reports%15==0) NSLog(@"USB3 Digital Audio: %@",self.status);
        reports++; _lastMeter=now;_peak=0;
    }
}
@end
