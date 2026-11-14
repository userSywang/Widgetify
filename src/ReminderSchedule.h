#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSArray<NSString *> *WidgetifyParseTimes(NSString *text,NSString **error);
FOUNDATION_EXPORT NSArray<NSString *> *WidgetifyDueTimes(NSDate *previous,NSDate *now,NSArray<NSString *> *times);
FOUNDATION_EXPORT NSString *WidgetifySlotKey(NSDate *date,NSString *time);

FOUNDATION_EXPORT BOOL WidgetifyIntervalIsDue(NSDate *previous,NSDate *now,NSDate *next);
FOUNDATION_EXPORT NSDictionary *WidgetifyApplyIntervalConfiguration(NSDictionary *old,NSDictionary *values,NSDate *now);
