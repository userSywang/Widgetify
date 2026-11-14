#import "ReminderSchedule.h"

NSArray<NSString *> *WidgetifyParseTimes(NSString *text,NSString **error){
    NSMutableSet *unique=[NSMutableSet new];
    NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^([01]?[0-9]|2[0-3]):([0-5][0-9])$" options:0 error:NULL];
    for(NSString *part in [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，、;；\n \t"]]){
        if(!part.length)continue;
        if(![regex firstMatchInString:part options:0 range:NSMakeRange(0,part.length)]){if(error)*error=[NSString stringWithFormat:@"时间“%@”无效，请使用 24 小时格式，例如 09:30。",part];return nil;}
        NSArray *pieces=[part componentsSeparatedByString:@":"];
        [unique addObject:[NSString stringWithFormat:@"%02ld:%02ld",(long)[pieces[0]integerValue],(long)[pieces[1]integerValue]]];
    }
    if(!unique.count || unique.count>32){if(error)*error=@"请输入 1–32 个不同的时间点。";return nil;}
    return [[unique allObjects]sortedArrayUsingSelector:@selector(compare:)];
}
NSArray<NSString *> *WidgetifyDueTimes(NSDate *previous,NSDate *now,NSArray<NSString *> *times){
    if(!previous || [now compare:previous]!=NSOrderedDescending)return @[];
    NSMutableArray *due=[NSMutableArray new];NSCalendar *calendar=NSCalendar.currentCalendar;
    for(NSString *time in times){NSArray *parts=[time componentsSeparatedByString:@":"];
        NSDate *target=[calendar dateBySettingHour:[parts[0]integerValue] minute:[parts[1]integerValue] second:0 ofDate:now options:0];
        if([previous compare:target]==NSOrderedAscending && [target compare:now]!=NSOrderedDescending && [now timeIntervalSinceDate:target]<=300)[due addObject:time];
    }return due;
}
NSString *WidgetifySlotKey(NSDate *date,NSString *time){
    NSDateComponents *c=[NSCalendar.currentCalendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld/%@",(long)c.year,(long)c.month,(long)c.day,time];
}
