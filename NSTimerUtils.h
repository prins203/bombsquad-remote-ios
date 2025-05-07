#import <UIKit/UIKit.h>

@interface NSTimer (Utils)
+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval
                                 usingBlock:(void (^)(void))fireBlock;
+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval
                        usingBlock:(void (^)(void))fireBlock;
@end
