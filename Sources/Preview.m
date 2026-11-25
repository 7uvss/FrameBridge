#import <AppKit/AppKit.h>
#import "AudioMonitor.h"
#import "Player.h"
#import "ShaderUpdates.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static void trace(NSString *message) {
    NSLog(@"%@",message);
    fprintf(stderr,"%s\n",message.UTF8String);
}

@interface Preview : NSObject <NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, NSWindowDelegate>
@end
@implementation Preview {
    AudioMonitor *_audio;
    Player *_player;
    ShaderUpdates *_shaderUpdates;
    NSUInteger _captureDrops;
    NSWindow *_window;
    NSMenuItem *_connectionStatus, *_detailMode, *_nativeMode;
    NSView *_canvas;
    AVCaptureSession *_session;
    dispatch_queue_t _queue;

    double _lastReport, _lastFrame;
    NSUInteger _count;
    BOOL _awaitingVideo;
    NSTimer *_watch;
    BOOL _starting;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _queue=dispatch_queue_create("FrameBridge.capture",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    NSMenu *menu=[NSMenu new]; NSMenuItem *root=[NSMenuItem new]; [menu addItem:root];
    root.submenu=[NSMenu new];
    [root.submenu addItemWithTitle:@"退出 FrameBridge" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *output=[NSMenuItem new];
    output.title=@"输出";
    [menu addItem:output];
    NSMenu *options=[[NSMenu alloc] initWithTitle:output.title];
    options.autoenablesItems=NO;
    output.submenu=options;
    _detailMode=[options addItemWithTitle:@"补帧" action:@selector(changeOutput:) keyEquivalent:@""];
    _nativeMode=[options addItemWithTitle:@"原生输出" action:@selector(changeOutput:) keyEquivalent:@""];
    _detailMode.target=self; _nativeMode.target=self;
    _detailMode.enabled=NO; _nativeMode.enabled=NO;
    _detailMode.state=NSControlStateValueOn;
    [options addItem:[NSMenuItem separatorItem]];
    NSMenuItem *retry=[options addItemWithTitle:@"重新连接" action:@selector(start:) keyEquivalent:@""];
    retry.target=self;
    _connectionStatus=[options addItemWithTitle:@"正在检查采集卡权限…" action:nil keyEquivalent:@""];
    _connectionStatus.enabled=NO;
    [NSApp setMainMenu:menu];
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1080,608)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"FrameBridge · 补帧";
    _window.delegate=self; _window.minSize=NSMakeSize(540,340);
    _window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    NSView *content=_window.contentView;
    _canvas=[[NSView alloc] initWithFrame:content.bounds];
    _canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    _canvas.wantsLayer=YES; _canvas.layer.backgroundColor=NSColor.blackColor.CGColor;
    [content addSubview:_canvas];
    _audio=[AudioMonitor new];
    NSScreen *screen=NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSNumber *lastScreen=[NSUserDefaults.standardUserDefaults objectForKey:@"PreviewDisplayID"];
    for(NSScreen *candidate in NSScreen.screens) {
        if([candidate.deviceDescription[@"NSScreenNumber"] isEqual:lastScreen]) { screen=candidate; break; }
    }
    if(screen) [_window setFrame:screen.visibleFrame display:NO];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self start:nil];
}
- (void)windowDidChangeScreen:(NSNotification *)note {
    NSWindow *window=note.object;
    NSNumber *number=window.screen.deviceDescription[@"NSScreenNumber"];
    if(window.visible && number) [NSUserDefaults.standardUserDefaults setObject:number forKey:@"PreviewDisplayID"];
}
- (void)changeOutput:(NSMenuItem *)sender {
    BOOL native=sender==_nativeMode;
    _detailMode.state=native ? NSControlStateValueOff : NSControlStateValueOn;
    _nativeMode.state=native ? NSControlStateValueOn : NSControlStateValueOff;
    _window.title=native ? @"FrameBridge · 原生输出" : @"FrameBridge · 补帧";
    dispatch_async(_queue,^{ self->_player.nativeOutput=native; });
}
- (void)status:(NSString *)s {
    trace(s);
    dispatch_async(dispatch_get_main_queue(),^{ self->_connectionStatus.title=s; });
}
- (void)start:(id)sender {
    if(_starting) return;
    if(!_player) {
        NSError *error=nil;
        _player=[[Player alloc] initWithError:&error];
        if(!_player) { [self status:error.localizedDescription ?: @"无法初始化 GPU 播放器"]; return; }
        NSString *build=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *folder=[[support URLByAppendingPathComponent:@"FrameBridge/Shaders"] URLByAppendingPathComponent:build];
        Player *player=_player;
        _shaderUpdates=[[ShaderUpdates alloc] initWithFolder:folder bundled:[NSBundle.mainBundle URLForResource:@"Pipeline" withExtension:@"metal"] apply:^BOOL(NSString *source, NSError **failure) {
            return [player installShader:source error:failure];
        }];
        _player.view.frame=_canvas.bounds;
        _player.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [_canvas addSubview:_player.view];
        _detailMode.enabled=YES; _nativeMode.enabled=YES;
    }
    AVAuthorizationStatus auth=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if(auth==AVAuthorizationStatusNotDetermined) {
        _starting=YES;
        [self status:@"等待相机授权 · 请在 macOS 提示中允许 FrameBridge 访问采集卡"];
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(),^{self->_starting=NO; [self start:nil];});
        }];
        return;
    }
    if(auth!=AVAuthorizationStatusAuthorized) {
        [self status:@"请在「系统设置 → 隐私与安全性 → 相机」允许 FrameBridge，然后重新连接"];
        if(sender) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"]];
        return;
    }
    [_audio start];
    _starting=YES; [_watch invalidate]; _watch=nil;
    dispatch_async(_queue,^{ [self connect]; });
}
- (void)connect {
    [_player reset];
    _captureDrops=0;
    if(_session) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:_session];
        [_session stopRunning]; _session=nil;
    }
    AVCaptureDevice *card=nil;
    for(AVCaptureDevice *d in [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                                        mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified].devices) {
        if([d.localizedName localizedCaseInsensitiveContainsString:@"USB3 Video"]) {card=d; break;}
    }
    NSString *failure=nil; NSError *error=nil;
    AVCaptureDeviceInput *input=card ? [AVCaptureDeviceInput deviceInputWithDevice:card error:&error] : nil;
    AVCaptureSession *session=[AVCaptureSession new];
    if(!card) failure=@"未找到 USB3 Video · 接好采集卡后点重新连接";
    else if(!input || ![session canAddInput:input]) failure=error.localizedDescription ?: @"采集设备不可用";
    if(!failure) {
        [session beginConfiguration];
        [session addInput:input];
        if([session canSetSessionPreset:AVCaptureSessionPreset1920x1080]) session.sessionPreset=AVCaptureSessionPreset1920x1080;
        AVCaptureDeviceFormat *chosen=nil; AVFrameRateRange *range=nil; double best=-1;
        for(AVCaptureDeviceFormat *format in card.formats) {
            CMVideoDimensions dims=CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            if(dims.width!=1920 || dims.height!=1080) continue;
            for(AVFrameRateRange *r in format.videoSupportedFrameRateRanges) {
                if(r.maxFrameRate<59 || r.minFrameRate>61) continue;
                OSType type=CMFormatDescriptionGetMediaSubType(format.formatDescription);
                BOOL preferred=type==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
                double score=preferred ? 2 : 1;
                if(score>best) {best=score;chosen=format;range=r;}
            }
        }
        CMTime duration=kCMTimeInvalid;
        if(chosen && [card lockForConfiguration:&error]) {
            card.activeFormat=chosen;
            duration=CMTimeMake(1,60);
            if(CMTimeCompare(duration,range.minFrameDuration)<0) duration=range.minFrameDuration;
            if(CMTimeCompare(duration,range.maxFrameDuration)>0) duration=range.maxFrameDuration;
            card.activeVideoMinFrameDuration=duration; card.activeVideoMaxFrameDuration=duration;
            [card unlockForConfiguration];
        }
        AVCaptureVideoDataOutput *monitor=[AVCaptureVideoDataOutput new];
        monitor.alwaysDiscardsLateVideoFrames=YES;
        monitor.videoSettings=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                            (id)kCVPixelBufferMetalCompatibilityKey:@YES,
                                            (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        [monitor setSampleBufferDelegate:self queue:_queue];
        if ([session canAddOutput:monitor]) [session addOutput:monitor];
        [session commitConfiguration];
        _session=session;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeError:) name:AVCaptureSessionRuntimeErrorNotification object:session];
        _awaitingVideo=YES;
        _lastFrame=_lastReport=CACurrentMediaTime(); _count=0;
        [session startRunning];
        // USB3 Video may renegotiate to 20 Hz during startRunning even after
        // accepting 60 Hz in beginConfiguration. Reapply to the live device.
        if(session.isRunning && chosen && CMTIME_IS_VALID(duration) && [card lockForConfiguration:&error]) {
            if(card.activeFormat!=chosen) card.activeFormat=chosen;
            card.activeVideoMinFrameDuration=duration;
            card.activeVideoMaxFrameDuration=duration;
            NSLog(@"USB3 Video format %@ · active %.2f fps",card.activeFormat,1/CMTimeGetSeconds(card.activeVideoMinFrameDuration));
            [card unlockForConfiguration];
        }
        if(!session.isRunning) failure=@"采集会话启动失败 · 请检查设备后重新连接";
    }
    [self status:failure ?: @"USB3 Video 已连接 · 等待视频帧"];
    dispatch_async(dispatch_get_main_queue(),^{
        self->_starting=NO;
        if(!failure) self->_watch=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){
            dispatch_async(self->_queue,^{
                if(CACurrentMediaTime()-self->_lastFrame>3 && self->_session.isRunning) {
                    self->_awaitingVideo=YES;
                    [self status:@"尚未收到视频帧 · 请检查 HDMI 输入、电源和采集卡连接"];
                }
            });
        }];
    });
}
- (void)runtimeError:(NSNotification *)n {
    NSError *error=n.userInfo[AVCaptureSessionErrorKey];
    [self status:[NSString stringWithFormat:@"采集错误 · %@ · 可重新连接",error.localizedDescription]];
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    if(_awaitingVideo) {
        _awaitingVideo=NO;
        [self status:@"USB3 Video 已连接"];
    }
    _lastFrame=CACurrentMediaTime(); _count++;
    [_player accept:CMSampleBufferGetImageBuffer(sample) pts:CMSampleBufferGetPresentationTimeStamp(sample)];
    double elapsed=_lastFrame-_lastReport;
    if(elapsed>=1) {
        CMVideoDimensions dims=CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sample));
        NSString *rates=[_player ratesForInterval:elapsed captureFPS:_count/elapsed drops:_captureDrops];
        NSString *status=[NSString stringWithFormat:@"%d×%d  ·  输入 %.0f · %@ · 采集丢 %lu · %@",dims.width,dims.height,_count/elapsed,rates,(unsigned long)_captureDrops,_audio.status];
        _captureDrops=0;
        if(_lastReport>0) trace(status);
        _lastReport=_lastFrame;_count=0;
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    _captureDrops++;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc,const char **argv){ @autoreleasepool {
    if(argc>1 && !strncmp(argv[1],"--bench",7)) {
        fprintf(stderr,"Use Benchmarks/run.py on a separate or idle Mac.\n"); return 2;
    }
    NSApplication *app=NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    Preview *delegate=[Preview new]; app.delegate=delegate; [app run];
    (void)delegate;
} return 0; }
