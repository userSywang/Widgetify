#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSArray<NSString *> *WidgetifyParseTimes(NSString *text,NSString **error);
FOUNDATION_EXPORT NSArray<NSString *> *WidgetifyDueTimes(NSDate *previous,NSDate *now,NSArray<NSString *> *times);
FOUNDATION_EXPORT NSString *WidgetifySlotKey(NSDate *date,NSString *time);
