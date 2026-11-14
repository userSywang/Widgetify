#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
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
- (BOOL)canBecomeKeyWindow{return self.preview;}
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
    NSMutableSet *shownTimes=[NSMutableSet new];
    for(NSString*i in [[self.contexts allKeys]sortedArrayUsingSelector:@selector(compare:)]){
        NSDictionary*c=self.contexts[i];if(![c[@"kind"]isEqual:@"water"])continue;NSDictionary*config=WidgetifyWaterConfiguration(i);if(![config[@"enabled"]boolValue])continue;
        for(NSString*time in WidgetifyDueTimes(self.lastCheck,now,WidgetifyParseTimes(config[@"times"],NULL))){
            NSString*slot=[i stringByAppendingFormat:@"/%@",WidgetifySlotKey(now,time)];if([self.fired containsObject:slot])continue;
            [self.fired addObject:slot];while(self.fired.count>128)[self.fired removeObjectAtIndex:0];[NSUserDefaults.standardUserDefaults setObject:self.fired.array forKey:FiredKey];
            if(![shownTimes containsObject:time]){[shownTimes addObject:time];[self present:config context:c window:[self.windows objectForKey:i] preview:NO];}
        }
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
    BOOL compact=[config[@"style"]integerValue]==1;CGFloat width=compact?370:316,height=compact?94:186;
    self.reminder=[[ReminderPanel alloc]initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];self.reminder.preview=preview;self.reminder.title=preview?@"喝水提醒预览":@"喝水提醒";self.reminder.releasedWhenClosed=NO;self.reminder.hidesOnDeactivate=NO;self.reminder.level=NSFloatingWindowLevel;self.reminder.opaque=NO;self.reminder.backgroundColor=NSColor.clearColor;self.reminder.hasShadow=YES;self.reminder.movableByWindowBackground=YES;self.reminder.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.reminder.appearance=source.effectiveAppearance?:NSApp.effectiveAppearance;
    if(context[@"dark"])self.reminder.appearance=[NSAppearance appearanceNamed:[context[@"dark"]boolValue]?NSAppearanceNameDarkAqua:NSAppearanceNameAqua];
    NSColor *accent=context[@"accent"]?:NSColor.controlAccentColor,*foreground=context[@"base"]?:NSColor.labelColor;
    NSVisualEffectView*v=[[NSVisualEffectView alloc]initWithFrame:NSMakeRect(0,0,width,height)];v.material=NSVisualEffectMaterialPopover;v.state=context[@"blur"] && ![context[@"blur"]boolValue]?NSVisualEffectStateInactive:NSVisualEffectStateActive;v.blendingMode=NSVisualEffectBlendingModeBehindWindow;v.wantsLayer=YES;v.layer.cornerRadius=compact?18:24;v.layer.masksToBounds=YES;v.layer.borderWidth=0.7;v.layer.borderColor=[NSColor.separatorColor colorWithAlphaComponent:0.35].CGColor;
    NSColor*bg=context[@"background"];if(bg && bg.alphaComponent>0.05){NSView*tint=[[NSView alloc]initWithFrame:v.bounds];tint.wantsLayer=YES;tint.layer.backgroundColor=bg.CGColor;tint.alphaValue=0.7;[v addSubview:tint];}
    self.reminder.contentView=v;
    NSImageView*icon=[[NSImageView alloc]initWithFrame:compact?NSMakeRect(18,38,34,34):NSMakeRect(22,120,40,40)];icon.image=[[NSImage imageWithSystemSymbolName:@"drop.fill" accessibilityDescription:@"喝水"]imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:compact?28:34 weight:NSFontWeightMedium]];icon.imageScaling=NSImageScaleProportionallyUpOrDown;icon.contentTintColor=accent;[v addSubview:icon];
    NSTextField*title=[self label:@"该喝水了" frame:compact?NSMakeRect(66,55,205,23):NSMakeRect(76,135,215,28) size:compact?17:21 color:foreground];title.font=[NSFont systemFontOfSize:compact?17:21 weight:NSFontWeightSemibold];[v addSubview:title];
    [v addSubview:[self label:preview?@"提醒预览 · 使用当前样式与停留时间":@"休息一下，喝一杯水吧。" frame:compact?NSMakeRect(66,34,278,19):NSMakeRect(24,91,270,24) size:12 color:NSColor.secondaryLabelColor]];
    self.countdown=[self label:@"" frame:compact?NSMakeRect(18,10,157,18):NSMakeRect(24,64,268,18) size:11 color:NSColor.tertiaryLabelColor];[v addSubview:self.countdown];
    NSButton*close=[NSButton buttonWithTitle:@"知道了" target:self action:@selector(dismiss:)];close.frame=compact?NSMakeRect(280,6,76,27):NSMakeRect(185,18,107,30);close.bezelStyle=NSBezelStyleRounded;[v addSubview:close];
    NSButton*later=[NSButton buttonWithTitle:@"10 分钟后提醒" target:self action:@selector(snooze:)];later.frame=compact?NSMakeRect(161,6,120,27):NSMakeRect(22,18,151,30);later.bezelStyle=NSBezelStyleRounded;[v addSubview:later];
    NSScreen*screen=source.screen?:NSScreen.mainScreen;NSRect safe=screen.visibleFrame;NSPoint position=NSMakePoint(NSMaxX(safe)-width-22,NSMaxY(safe)-height-22);
    if(source && [config[@"position"]integerValue]==0){NSRect frame=source.frame;position=NSMakePoint(NSMaxX(frame)+12,NSMaxY(frame)-height);if(position.x+width>NSMaxX(safe))position.x=frame.origin.x-width-12;position.x=MAX(NSMinX(safe)+12,MIN(position.x,NSMaxX(safe)-width-12));position.y=MAX(NSMinY(safe)+12,MIN(position.y,NSMaxY(safe)-height-12));}
    [self.reminder setFrameOrigin:position];[self.reminder orderFrontRegardless];if(preview)[self.reminder makeKeyAndOrderFront:nil];
    NSInteger seconds=[config[@"duration"]integerValue];if(seconds>0){self.expires=[NSDate dateWithTimeIntervalSinceNow:seconds];self.closeTimer=[NSTimer timerWithTimeInterval:seconds repeats:NO block:^(NSTimer*t){[self dismiss:nil];}];[NSRunLoop.mainRunLoop addTimer:self.closeTimer forMode:NSRunLoopCommonModes];self.countdownTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*t){[self updateCountdown];}];[NSRunLoop.mainRunLoop addTimer:self.countdownTimer forMode:NSRunLoopCommonModes];[self updateCountdown];}else self.countdown.stringValue=@"停留至手动关闭";
    if([config[@"sound"]boolValue])[[NSSound soundNamed:@"Glass"]play];
}
- (void)updateCountdown{self.countdown.stringValue=[NSString stringWithFormat:@"%ld 秒后自动关闭",(long)MAX(0,ceil(self.expires.timeIntervalSinceNow))];}
- (void)dismiss:(id)sender{[self.closeTimer invalidate];[self.countdownTimer invalidate];self.closeTimer=nil;self.countdownTimer=nil;[self.reminder orderOut:nil];self.reminder=nil;}
- (void)snooze:(id)sender{
    NSDictionary*c=self.activeConfig,*context=self.activeContext;NSString*i=context[@"id"];[self dismiss:nil];NSTimer*t=[NSTimer timerWithTimeInterval:600 repeats:NO block:^(NSTimer*t){NSWindow*w=[self.windows objectForKey:i];if(w && [WidgetifyWaterConfiguration(i)[@"enabled"]boolValue])[self present:c context:WidgetifyContext(w)?:context window:w preview:NO];}];[NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}
@end
#ifndef ENHANCEMENTS_TEST
__attribute__((constructor))static void LoadEnhancements(void){@autoreleasepool{WidgetifyInstallDirectoryReferences();}dispatch_async(dispatch_get_main_queue(),^{NSTimer*t=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*t){[[WidgetifyEnhancements shared]install];}];[NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];});}
#else
int main(void){@autoreleasepool{
    NSString *error=nil;
    NSCAssert(([WidgetifyParseTimes(@"9:30，11:00, 09:30\n16:00",&error)isEqual:@[@"09:30",@"11:00",@"16:00"]]),@"Normalization");
    for(NSString *bad in @[@"24:00",@"12:60",@"-1:30",@"9:3",@"",@"12:00abc",@"09:00:00"])NSCAssert(WidgetifyParseTimes(bad,&error)==nil,@"Invalid time");
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
    NSLog(@"PASS: time parsing, desktop boundaries, due-time protection, directory references without moving originals, unrelated operations unchanged.");
}return 0;}
#endif
