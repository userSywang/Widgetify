#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/QuartzCore.h>
extern void *WidgetifyCreateWaterReminder(void *,void *,void *,void *);
#import "OriginalFolderBridge.h"
#import "ComponentIntegration.h"
#import "ComponentSettings.h"
#import "ReminderSchedule.h"
#import "DirectoryReferences.h"

static NSString *const TimeKey=@"custom.enhancements.water.times";
static NSString *const EnabledKey=@"custom.enhancements.water.enabled";
static NSString *const HideKey=@"custom.enhancements.originalFolders.hideDesktop";
static NSString *const FiredKey=@"custom.enhancements.water.deliveredSlots";
@interface ReminderPanel:NSPanel
@property BOOL preview;
@end
@implementation ReminderPanel
- (BOOL)canBecomeKeyWindow{return YES;}
- (BOOL)canBecomeMainWindow{return NO;}
@end
@interface WidgetifyEnhancements:NSObject<ComponentSettingsDelegate>
@property OriginalFolderBridge *folders;
@property NSMutableOrderedSet *fired;
@property NSDate *lastCheck,*lastScan;
@property NSMutableDictionary<NSString*,NSDictionary*> *contexts;
@property NSMapTable<NSString*,NSWindow*> *windows;
@property ReminderPanel *reminder;
@property NSTimer *closeTimer,*countdownTimer;
@property NSTextField *countdown;
@property NSDate *expires;
@property NSDictionary *activeConfig,*activeContext;
@property(weak) NSWindow *activeSource;
@property BOOL initialized,quitting;
+ (instancetype)shared;
@end
@implementation WidgetifyEnhancements
+ (instancetype)shared{static id s;static dispatch_once_t once;dispatch_once(&once,^{s=[self new];});return s;}
- (void)install{
    if(!NSApp.isRunning)return;
    if(!self.initialized){
        self.initialized=YES;self.folders=[OriginalFolderBridge new];self.fired=[NSMutableOrderedSet orderedSetWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:FiredKey]?:@[]];
        self.contexts=[NSMutableDictionary new];self.windows=[NSMapTable strongToWeakObjectsMapTable];self.lastCheck=NSDate.date;
        WidgetifyInstallComponentIntegration(self);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(terminate:) name:NSApplicationWillTerminateNotification object:nil];
        // Retire requests from the earlier global scheduler; component settings
        // now own their schedules and the app-native presentation.
        [UNUserNotificationCenter.currentNotificationCenter getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest*>*requests){NSMutableArray*ids=[NSMutableArray new];for(UNNotificationRequest*r in requests)if([r.identifier hasPrefix:@"custom.water."])[ids addObject:r.identifier];[UNUserNotificationCenter.currentNotificationCenter removePendingNotificationRequestsWithIdentifiers:ids];}];
    }
    if(self.quitting)return;
    NSDate *now=NSDate.date;
    if(!self.lastScan||[now timeIntervalSinceDate:self.lastScan]>=2){
        NSMutableSet *alive=[NSMutableSet new];
        NSURL *snapshotURL=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Widgetify/autosaved.widgetlist4"];
        NSData *snapshotData=[NSData dataWithContentsOfURL:snapshotURL];id snapshot=snapshotData?[NSJSONSerialization JSONObjectWithData:snapshotData options:0 error:NULL]:nil;
        NSSet *active=[snapshot isKindOfClass:NSArray.class]?[NSSet setWithArray:[snapshot valueForKey:@"id"]]:nil;
        for(NSWindow*w in NSApp.windows){NSDictionary*c=WidgetifyContext(w);if(!c)continue;NSString*i=c[@"id"];if(active && ![active containsObject:i])continue;[alive addObject:i];self.contexts[i]=c;[self.windows setObject:w forKey:i];
            if([c[@"kind"]isEqual:@"water"] && ![NSUserDefaults.standardUserDefaults objectForKey:WidgetifyWaterKey(i)]){
                NSMutableDictionary*config=[WidgetifyWaterConfiguration(i)mutableCopy];NSString*t=[NSUserDefaults.standardUserDefaults stringForKey:TimeKey];if(t)config[@"times"]=t;config[@"enabled"]=@([NSUserDefaults.standardUserDefaults boolForKey:EnabledKey]);[NSUserDefaults.standardUserDefaults setObject:config forKey:WidgetifyWaterKey(i)];
            }
        }
        for(NSString*i in [self.contexts.allKeys copy])if(![alive containsObject:i]){[self.contexts removeObjectForKey:i];[self.windows removeObjectForKey:i];}
        [self folderOptionsChanged];self.lastScan=now;
    }
    BOOL presented=NO;
    for(NSString*i in [[self.contexts allKeys]sortedArrayUsingSelector:@selector(compare:)]){
        NSDictionary*c=self.contexts[i];if(![c[@"kind"]isEqual:@"water"])continue;
        NSDictionary*config=WidgetifyWaterConfiguration(i);if(![config[@"enabled"]boolValue])continue;
        NSTimeInterval stamp=[config[@"nextReminderAt"]doubleValue];
        NSDate *next=stamp>0?[NSDate dateWithTimeIntervalSince1970:stamp]:nil;
        if(next && [next compare:now]==NSOrderedDescending && [now compare:self.lastCheck]!=NSOrderedAscending)continue;
        BOOL due=WidgetifyIntervalIsDue(self.lastCheck,now,next);
        NSMutableDictionary *updated=[config mutableCopy];
        updated[@"nextReminderAt"]=@([now timeIntervalSince1970]+MAX(1,MIN(240,[config[@"intervalMinutes"]integerValue]))*60);
        [NSUserDefaults.standardUserDefaults setObject:updated forKey:WidgetifyWaterKey(i)];
        if(due && !presented){presented=YES;updated[@"lastReminderAt"]=@(now.timeIntervalSince1970);[NSUserDefaults.standardUserDefaults setObject:updated forKey:WidgetifyWaterKey(i)];[self present:updated context:c window:[self.windows objectForKey:i] preview:NO];}
    }
    self.lastCheck=now;
    // Optional navigation only: it opens/focuses the actual component, never an
    // independent enhancement settings window.
    NSMenu*m=NSApp.mainMenu.numberOfItems?[NSApp.mainMenu itemAtIndex:0].submenu:nil;
    if(m && ![m itemWithTag:90740]){
        for(NSArray*spec in @[@[@"喝水组件设置…",@"openWater:"],@[@"文件夹组件设置…",@"openFolders:"]]){NSMenuItem*item=[[NSMenuItem alloc]initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""];item.target=self;item.tag=[spec[1]isEqual:@"openWater:"]?90740:90741;[m insertItem:item atIndex:MIN(2,m.numberOfItems)];}
    }
}
- (NSView*)settingsForComponent:(NSDictionary*)context window:(NSWindow*)window{return WidgetifySettingsView(context,window,self.folders,self);}
- (void)folderOptionsChanged{if(!self.quitting)[self.folders synchronizeWithHiding:[NSUserDefaults.standardUserDefaults boolForKey:HideKey]];}
- (void)terminate:(id)sender{self.quitting=YES;[self dismiss:nil];[self.folders restoreAll];}
- (void)openKind:(NSString*)kind{
    for(NSWindow*w in NSApp.windows){NSDictionary*c=WidgetifyContext(w);if(![c[@"kind"]isEqual:kind])continue;[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];WidgetifyOpenOriginalSettings(w);return;}
}
- (void)openWater:(id)sender{[self openKind:@"water"];}
- (void)openFolders:(id)sender{[self openKind:@"folder"];}
- (void)previewWater:(NSDictionary*)config context:(NSDictionary*)context window:(NSWindow*)window{[self present:config context:WidgetifyContext(window)?:context window:window preview:YES];}
- (NSTextField*)label:(NSString*)s frame:(NSRect)r size:(CGFloat)size color:(NSColor*)color{
    NSTextField*v=[NSTextField wrappingLabelWithString:s];v.frame=r;v.font=[NSFont systemFontOfSize:size];v.textColor=color;return v;
}
- (void)present:(NSDictionary*)config context:(NSDictionary*)context window:(NSWindow*)source preview:(BOOL)preview{
    [self dismiss:nil];self.activeConfig=config;self.activeContext=context;self.activeSource=source;
    BOOL compact=[config[@"style"]integerValue]==1;CGFloat width=compact?366:340,height=compact?116:226;
    self.reminder=[[ReminderPanel alloc]initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];self.reminder.preview=preview;self.reminder.title=preview?@"喝水提醒预览":@"喝水提醒";self.reminder.releasedWhenClosed=NO;self.reminder.hidesOnDeactivate=NO;self.reminder.level=NSFloatingWindowLevel;self.reminder.opaque=NO;self.reminder.backgroundColor=NSColor.clearColor;self.reminder.hasShadow=YES;self.reminder.movableByWindowBackground=YES;self.reminder.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.reminder.appearance=source.effectiveAppearance?:NSApp.effectiveAppearance;
    NSColor *ink=[(context[@"base"]?:NSColor.labelColor) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if(ink){CGFloat luminance=0.2126*ink.redComponent+0.7152*ink.greenComponent+0.0722*ink.blueComponent;self.reminder.appearance=[NSAppearance appearanceNamed:luminance>0.6?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];}
    else if(context[@"dark"])self.reminder.appearance=[NSAppearance appearanceNamed:[context[@"dark"]boolValue]?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];
    NSVisualEffectView*v=[[NSVisualEffectView alloc]initWithFrame:NSMakeRect(0,0,width,height)];
    v.material=NSVisualEffectMaterialHUDWindow;v.state=context[@"blur"] && ![context[@"blur"]boolValue]?NSVisualEffectStateInactive:NSVisualEffectStateActive;
    v.blendingMode=NSVisualEffectBlendingModeBehindWindow;v.wantsLayer=YES;
    v.layer.cornerRadius=compact?20:22;v.layer.masksToBounds=YES;
    v.layer.borderWidth=0.5;v.layer.borderColor=[NSColor.whiteColor colorWithAlphaComponent:0.12].CGColor;
    NSColor*bg=context[@"background"];
    if(!bg || bg.alphaComponent<0.1)bg=[NSColor colorWithCalibratedRed:0.11 green:0.13 blue:0.16 alpha:0.88];
    NSView*tint=[[NSView alloc]initWithFrame:v.bounds];tint.wantsLayer=YES;tint.layer.backgroundColor=bg.CGColor;tint.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[v addSubview:tint];
    NSMutableDictionary *presentation=[config mutableCopy];presentation[@"preview"]=@(preview);
    presentation[@"expires"]=@(NSDate.date.timeIntervalSince1970+[config[@"duration"]integerValue]);
    NSView *content=CFBridgingRelease(WidgetifyCreateWaterReminder((__bridge void*)source.contentView,(__bridge void*)presentation,(__bridge void*)(context?:@{}),(__bridge void*)self));
    content.frame=v.bounds;content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[v addSubview:content];
    self.reminder.contentView=v;
    NSScreen*screen=source.screen?:NSScreen.mainScreen;NSRect safe=screen.visibleFrame;NSPoint position=NSMakePoint(NSMaxX(safe)-width-22,NSMaxY(safe)-height-22);
    if(source && [config[@"position"]integerValue]==0){NSRect frame=source.frame;position=NSMakePoint(NSMaxX(frame)+12,NSMaxY(frame)-height);if(position.x+width>NSMaxX(safe))position.x=frame.origin.x-width-12;position.x=MAX(NSMinX(safe)+12,MIN(position.x,NSMaxX(safe)-width-12));position.y=MAX(NSMinY(safe)+12,MIN(position.y,NSMaxY(safe)-height-12));}
    NSPanel *panel=self.reminder;BOOL animate=!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    [panel setFrameOrigin:NSMakePoint(position.x,position.y-(animate?10:0))];panel.alphaValue=animate?0:1;
    [panel orderFrontRegardless];if(preview || NSApp.isActive)[panel makeKeyAndOrderFront:nil];if(preview)[NSApp activateIgnoringOtherApps:YES];
    if(animate)[NSAnimationContext runAnimationGroup:^(NSAnimationContext *animation){animation.duration=0.28;animation.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];panel.animator.alphaValue=1;[panel.animator setFrameOrigin:position];} completionHandler:nil];
    NSInteger seconds=[config[@"duration"]integerValue];
    if(seconds>0){self.expires=[NSDate dateWithTimeIntervalSinceNow:seconds];__weak typeof(self) weakSelf=self;self.closeTimer=[NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer*t){[weakSelf dismiss:nil];}];[NSRunLoop.mainRunLoop addTimer:self.closeTimer forMode:NSRunLoopCommonModes];}
    if([config[@"sound"]boolValue])[[NSSound soundNamed:@"Glass"]play];
}
- (void)dismiss:(id)sender{
    [self.closeTimer invalidate];[self.countdownTimer invalidate];self.closeTimer=nil;self.countdownTimer=nil;
    NSPanel *panel=self.reminder;self.reminder=nil;if(!panel)return;
    if(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion){[panel orderOut:nil];return;}
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *animation){animation.duration=0.16;panel.animator.alphaValue=0;} completionHandler:^{[panel orderOut:nil];}];
}
- (void)snooze:(id)sender{
    if(!self.reminder || self.reminder.preview){[self dismiss:nil];return;}
    NSString*i=self.activeContext[@"id"];NSMutableDictionary*c=[WidgetifyWaterConfiguration(i)mutableCopy];
    c[@"nextReminderAt"]=@(NSDate.date.timeIntervalSince1970+600);
    [NSUserDefaults.standardUserDefaults setObject:c forKey:WidgetifyWaterKey(i)];[self dismiss:nil];
}
@end
#ifndef ENHANCEMENTS_TEST
__attribute__((constructor))static void LoadEnhancements(void){@autoreleasepool{WidgetifyInstallDirectoryReferences();}dispatch_async(dispatch_get_main_queue(),^{NSTimer*t=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*t){[[WidgetifyEnhancements shared]install];}];[NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];});}
#else
int main(void){@autoreleasepool{
    NSString *error=nil;
    NSCAssert(([WidgetifyParseTimes(@"9:30，11:00, 09:30\n16:00",&error)isEqual:@[@"09:30",@"11:00",@"16:00"]]),@"Normalization");
    for(NSString *bad in @[@"24:00",@"12:60",@"-1:30",@"9:3",@"",@"12:00abc",@"09:00:00"])NSCAssert(WidgetifyParseTimes(bad,&error)==nil,@"Invalid time");
    NSDate *start=[NSDate dateWithTimeIntervalSince1970:1800000000],*next=[start dateByAddingTimeInterval:60];
    NSCAssert(WidgetifyIntervalIsDue([next dateByAddingTimeInterval:-1],[next dateByAddingTimeInterval:1],next),@"Interval crosses due date");
    NSCAssert(!WidgetifyIntervalIsDue(start,[start dateByAddingTimeInterval:30],next),@"No early interval");
    NSCAssert(!WidgetifyIntervalIsDue(start,[next dateByAddingTimeInterval:600],next),@"Wake skips backlog");
    NSCAssert(!WidgetifyIntervalIsDue([next dateByAddingTimeInterval:30],[next dateByAddingTimeInterval:31],next),@"Restart skips overdue interval");
    NSDictionary *intervalConfig=@{@"enabled":@YES,@"intervalMinutes":@45,@"nextReminderAt":@(start.timeIntervalSince1970+2700),@"style":@0};
    NSDictionary *styleChange=WidgetifyApplyIntervalConfiguration(intervalConfig,@{@"enabled":@YES,@"intervalMinutes":@45,@"style":@1},start);
    NSCAssert([styleChange[@"nextReminderAt"]isEqual:intervalConfig[@"nextReminderAt"]],@"Appearance does not reset interval");
    NSDictionary *intervalChange=WidgetifyApplyIntervalConfiguration(intervalConfig,@{@"enabled":@YES,@"intervalMinutes":@30},start);
    NSCAssert([intervalChange[@"nextReminderAt"]doubleValue]==start.timeIntervalSince1970+1800,@"Changed interval restarts clock");
    NSCAssert(WidgetifyApplyIntervalConfiguration(intervalConfig,@{@"intervalMinutes":@0},start)==nil,@"Reject zero interval");
    NSURL *desktop=[NSURL fileURLWithPath:@"/example/Desktop" isDirectory:YES];
    NSCAssert(WidgetifyIsDesktopChild([NSURL fileURLWithPath:@"/example/Desktop/Folder"],desktop),@"Desktop child");
    NSCAssert(!WidgetifyIsDesktopChild([NSURL fileURLWithPath:@"/example/DesktopOther/Folder"],desktop),@"Prefix collision");
    NSCAssert(!WidgetifyIsDesktopChild([NSURL fileURLWithPath:@"/example/Desktop/Parent/Nested"],desktop),@"Nested folder");
    NSCalendar *calendar=NSCalendar.currentCalendar;NSDateComponents *c=[NSDateComponents new];c.year=2026;c.month=11;c.day=14;c.hour=9;c.minute=30;
    NSDate *target=[calendar dateFromComponents:c];
    NSCAssert(([WidgetifyDueTimes([target dateByAddingTimeInterval:-1],[target dateByAddingTimeInterval:1],@[@"09:30"])isEqual:@[@"09:30"]]),@"Crossed reminder time");
    NSCAssert(WidgetifyDueTimes([target dateByAddingTimeInterval:1],[target dateByAddingTimeInterval:2],@[@"09:30"]).count==0,@"No duplicate within minute");
    NSCAssert(WidgetifyDueTimes([target dateByAddingTimeInterval:-1],[target dateByAddingTimeInterval:600],@[@"09:30"]).count==0,@"Skip stale reminders");
    NSFileManager *fm=NSFileManager.defaultManager;NSURL *fixture=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *source=[fixture URLByAppendingPathComponent:@"source/original" isDirectory:YES],*storage=[fixture URLByAppendingPathComponent:@"storage" isDirectory:YES];
    [fm createDirectoryAtURL:source withIntermediateDirectories:YES attributes:nil error:NULL];[fm createDirectoryAtURL:storage withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *sentinel=[source URLByAppendingPathComponent:@"sentinel.txt"];[@"unchanged" writeToURL:sentinel atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *previous=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"custom.references.links.v1"];NSError *referenceError=nil;
    NSCAssert(WidgetifyProtectDirectoryImports(@[source],&referenceError),@"Directory grant %@",referenceError);
    NSURL *reference=[storage URLByAppendingPathComponent:@"original" isDirectory:YES];NSCAssert([fm moveItemAtURL:source toURL:reference error:&referenceError],@"Reference instead of move %@",referenceError);
    NSCAssert([fm fileExistsAtPath:source.path] && [[NSString stringWithContentsOfURL:sentinel encoding:NSUTF8StringEncoding error:NULL]isEqual:@"unchanged"],@"Original directory and content survive");
    NSCAssert([[fm destinationOfSymbolicLinkAtPath:reference.path error:NULL]isEqual:source.path],@"Managed reference points to original");
    NSCAssert([WidgetifyOriginalDirectoryReference(reference)[@"source"]isEqual:source.path],@"Display and reveal use original path");
    NSURL *ordinary=[fixture URLByAppendingPathComponent:@"ordinary.txt"],*renamed=[fixture URLByAppendingPathComponent:@"renamed.txt"];[@"normal" writeToURL:ordinary atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSCAssert([fm moveItemAtURL:ordinary toURL:renamed error:NULL] && ![fm fileExistsAtPath:ordinary.path],@"Unrelated moves keep native behavior");
    [fm removeItemAtURL:fixture error:NULL];if(previous)[NSUserDefaults.standardUserDefaults setObject:previous forKey:@"custom.references.links.v1"];else[NSUserDefaults.standardUserDefaults removeObjectForKey:@"custom.references.links.v1"];
    NSLog(@"PASS: interval scheduling, wake/restart protection, appearance changes preserve due date, time parsing, desktop boundaries, protected directory references.");
}return 0;}
#endif
