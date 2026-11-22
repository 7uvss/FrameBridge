#import <Foundation/Foundation.h>

@interface ShaderUpdates : NSObject
- (instancetype)initWithFolder:(NSURL *)folder bundled:(NSURL *)bundled
                         apply:(BOOL (^)(NSString *source, NSError **error))apply;
@end
