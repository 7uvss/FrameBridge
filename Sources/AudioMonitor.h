#import <AVFoundation/AVFoundation.h>
@interface AudioMonitor : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property(atomic,copy,readonly) NSString *status;
- (void)start;
@end
