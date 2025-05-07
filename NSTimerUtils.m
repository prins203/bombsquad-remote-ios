#import "NSTimerUtils.h"

typedef void (^PSYTimerBlock)(NSTimer *);

@interface NSTimer (UtilsPrivate)
+ (void)PSYBlockTimer_executeBlockWithTimer:(NSTimer *)timer;
@end

@implementation NSTimer (Utils)
+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval
                                usingBlock:(void (^)(void))fireBlock {
    return [NSTimer scheduledTimerWithTimeInterval:interval
                                          target:self
                                        selector:@selector(blockInvoke:)
                                        userInfo:[fireBlock copy]
                                         repeats:NO];
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval
                       usingBlock:(void (^)(void))fireBlock {
    return [NSTimer timerWithTimeInterval:interval
                                 target:self
                               selector:@selector(blockInvoke:)
                               userInfo:[fireBlock copy]
                                repeats:NO];
}

+ (void)blockInvoke:(NSTimer *)timer {
    void (^block)(void) = timer.userInfo;
    if (block) {
        block();
    }
}
@end

@implementation NSTimer (Utils_Private)
+ (void)PSYBlockTimer_executeBlockWithTimer:(NSTimer *)timer {
  PSYTimerBlock block = [timer userInfo];
  block(timer);
}
@end
