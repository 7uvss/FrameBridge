#import "ShaderUpdates.h"
#import <fcntl.h>
#import <unistd.h>

@implementation ShaderUpdates {
    dispatch_source_t _watch;
}
- (instancetype)initWithFolder:(NSURL *)folder bundled:(NSURL *)bundled
                         apply:(BOOL (^)(NSString *, NSError **))apply {
    if(!(self=[super init])) return nil;
    NSError *err=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&err]) {
        NSLog(@"FrameBridge shader updates: %@",err); return nil;
    }
    int fd=open(folder.fileSystemRepresentation,O_EVTONLY|O_CLOEXEC);
    if(fd<0) { NSLog(@"FrameBridge shader updates: open failed (%d)",errno); return nil; }
    dispatch_queue_t queue=dispatch_queue_create("FrameBridge.shader-updates",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    _watch=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_WRITE,queue);
    if(!_watch) {close(fd); return nil;}
    NSURL *file=[folder URLByAppendingPathComponent:@"Pipeline.metal"];
    __block NSString *lastAttempt=nil;
    __block BOOL active=NO;
    void (^reload)(void)=^{
        @autoreleasepool {
            NSError *error=nil;
            NSString *source=[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
            BOOL removed=!source && [error.domain isEqualToString:NSCocoaErrorDomain] && error.code==NSFileReadNoSuchFileError;
            if(removed) {
                lastAttempt=nil;
                if(!active) return;
                source=[NSString stringWithContentsOfURL:bundled encoding:NSUTF8StringEncoding error:&error];
            }
            if(!source) { NSLog(@"FrameBridge shader read failed: %@",error); return; }
            if([lastAttempt isEqualToString:source]) return;
            if(!removed) lastAttempt=source;
            if(apply(source,&error)) {
                active=!removed;
                NSLog(@"FrameBridge shader applied: %@",active ? file.path : bundled.path);
            } else NSLog(@"FrameBridge shader rejected: %@",error);
        }
    };
    dispatch_source_set_event_handler(_watch,reload);
    dispatch_source_set_cancel_handler(_watch,^{close(fd);});
    dispatch_resume(_watch);
    dispatch_async(queue,reload);
    return self;
}
- (void)dealloc { if(_watch) dispatch_source_cancel(_watch); }
@end
