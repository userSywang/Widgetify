#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreGraphics/CoreGraphics.h>
#import <pwd.h>
#import <unistd.h>

static NSString *const FolderKey=@"custom.enhancements.folders.v1";
static NSString *const TimeKey=@"custom.enhancements.water.times";
static NSString *const EnabledKey=@"custom.enhancements.water.enabled";
static NSString *const NoticePrefix=@"custom.water.daily.";

static NSString *CurrentVersion(void) {return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"dev";}

static NSArray<NSString *> *ParseTimes(NSString *text, NSString **error) {
    NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@",，、;；\n \t"];
    NSMutableSet *unique=[NSMutableSet set];
    NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^([01]?[0-9]|2[0-3]):([0-5][0-9])$" options:0 error:NULL];
    for(NSString *part in [text componentsSeparatedByCharactersInSet:separators]) {
        if(!part.length) continue;
        if(![regex firstMatchInString:part options:0 range:NSMakeRange(0,part.length)]) {if(error)*error=[NSString stringWithFormat:@"时间“%@”无效，请使用 24 小时格式，例如 09:30。",part];return nil;}
        NSArray *pieces=[part componentsSeparatedByString:@":"];
        [unique addObject:[NSString stringWithFormat:@"%02ld:%02ld",(long)[pieces[0] integerValue],(long)[pieces[1] integerValue]]];
    }
    if(!unique.count || unique.count>32) {if(error)*error=@"请输入 1–32 个不同的时间点。";return nil;}
    return [[unique allObjects] sortedArrayUsingSelector:@selector(compare:)];
}
static BOOL OnDesktop(NSURL *url, NSURL *desktop) {
    return [[url.URLByDeletingLastPathComponent.URLByStandardizingPath.URLByResolvingSymlinksInPath path] isEqualToString:desktop.URLByStandardizingPath.URLByResolvingSymlinksInPath.path];
}
static NSURL *DesktopURL(void) {struct passwd *user=getpwuid(getuid());if(user && user->pw_dir)return [[NSURL fileURLWithPath:[NSString stringWithUTF8String:user->pw_dir] isDirectory:YES]URLByAppendingPathComponent:@"Desktop" isDirectory:YES];return [[NSFileManager defaultManager]URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject.URLByResolvingSymlinksInPath;}
static BOOL IsHidden(NSURL *url) {[url removeCachedResourceValueForKey:NSURLIsHiddenKey];NSNumber *hidden=nil;[url getResourceValue:&hidden forKey:NSURLIsHiddenKey error:NULL];return hidden.boolValue;}
static void Message(NSString *title,NSString *detail) {NSAlert *alert=[NSAlert new];alert.messageText=title;alert.informativeText=detail?:@"";[alert addButtonWithTitle:@"好"];[alert runModal];}

@interface WidgetifyEnhancements : NSObject <NSTableViewDataSource,NSTableViewDelegate,UNUserNotificationCenterDelegate,NSWindowDelegate>
@property NSWindow *settingsWindow;
@property NSPanel *folderWindow;
@property NSTableView *table;
@property NSTextField *timesField;
@property NSTextField *statusField;
@property NSButton *enabled;
@property NSMutableArray<NSMutableDictionary *> *folders;
@property NSMutableDictionary<NSString *,NSURL *> *activeURLs;
@property id<UNUserNotificationCenterDelegate> previousDelegate;
@property BOOL installing;
@property BOOL initialized;
@property NSStatusItem *statusItem;
+ (instancetype)shared;
@end

@implementation WidgetifyEnhancements
+ (instancetype)shared {static WidgetifyEnhancements *s;static dispatch_once_t once;dispatch_once(&once,^{s=[self new];s.folders=[NSMutableArray array];s.activeURLs=[NSMutableDictionary dictionary];});return s;}
- (void)install {
    if(!NSApp.isRunning)return;
    if(!self.initialized){
        self.initialized=YES;
        self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        self.statusItem.button.title=@"W+";
        self.statusItem.button.toolTip=[@"Widgetify 增强功能 " stringByAppendingString:CurrentVersion()];
        NSMenu *quickMenu=[NSMenu new];
        NSMenuItem *versionItem=[[NSMenuItem alloc]initWithTitle:[@"Widgetify " stringByAppendingString:CurrentVersion()] action:nil keyEquivalent:@""];versionItem.enabled=NO;[quickMenu addItem:versionItem];
        NSMenuItem *water=[[NSMenuItem alloc]initWithTitle:@"喝水提醒设置…" action:@selector(showSettings:) keyEquivalent:@""];water.target=self;[quickMenu addItem:water];
        NSMenuItem *folder=[[NSMenuItem alloc]initWithTitle:@"文件夹集中管理…" action:@selector(showFolders:) keyEquivalent:@""];folder.target=self;[quickMenu addItem:folder];
        self.statusItem.menu=quickMenu;
        [self loadFolders];
        UNUserNotificationCenter *center=[UNUserNotificationCenter currentNotificationCenter];self.previousDelegate=center.delegate;center.delegate=self;
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){if(settings.authorizationStatus==UNAuthorizationStatusAuthorized && [[NSUserDefaults standardUserDefaults]boolForKey:EnabledKey])dispatch_async(dispatch_get_main_queue(),^{[self reschedule];});}];
        if(self.folders.count){[self showFolders:nil];[self dockFolders:nil];}
        NSString *welcomeKey=@"custom.enhancements.welcomed.version";
        if(![[NSUserDefaults.standardUserDefaults stringForKey:welcomeKey]isEqualToString:CurrentVersion()]){
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self showSettings:nil];[NSUserDefaults.standardUserDefaults setObject:CurrentVersion() forKey:welcomeKey];});
        }
    }
    NSMenu *menu=NSApp.mainMenu.numberOfItems?[NSApp.mainMenu itemAtIndex:0].submenu:nil;
    if(!menu || [menu itemWithTag:90731])return;
    NSMenuItem *item=[[NSMenuItem alloc]initWithTitle:@"增强设置…" action:@selector(showSettings:) keyEquivalent:@""];item.target=self;item.tag=90731;
    [menu insertItem:[NSMenuItem separatorItem] atIndex:MIN(2,menu.numberOfItems)];[menu insertItem:item atIndex:MIN(3,menu.numberOfItems)];
    NSMenuItem *folders=[[NSMenuItem alloc]initWithTitle:@"文件夹集中管理" action:@selector(showFolders:) keyEquivalent:@""];folders.target=self;[menu insertItem:folders atIndex:MIN(4,menu.numberOfItems)];
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame font:(CGFloat)size {
    NSTextField *label=[NSTextField wrappingLabelWithString:text];label.frame=frame;label.font=[NSFont systemFontOfSize:size];return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame parent:(NSView *)parent {
    NSButton *b=[NSButton buttonWithTitle:title target:self action:action];b.frame=frame;[parent addSubview:b];return b;
}
- (void)showSettings:(id)sender {
    if(!self.settingsWindow){
        NSRect rect=NSMakeRect(0,0,570,440);
        self.settingsWindow=[[NSWindow alloc]initWithContentRect:rect styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.title=[NSString stringWithFormat:@"Widgetify %@ · 增强设置",CurrentVersion()];self.settingsWindow.releasedWhenClosed=NO;
        NSView *v=self.settingsWindow.contentView;
        [v addSubview:[self label:@"喝水定时提醒 · 顶部 W+ 可再次打开" frame:NSMakeRect(24,384,520,30) font:20]];
        self.enabled=[NSButton checkboxWithTitle:@"开启每日喝水提醒" target:nil action:nil];self.enabled.frame=NSMakeRect(24,348,500,28);[v addSubview:self.enabled];
        [v addSubview:[self label:@"每天的提醒时间（24 小时制，用逗号分隔）" frame:NSMakeRect(24,304,520,28) font:13]];
        self.timesField=[[NSTextField alloc]initWithFrame:NSMakeRect(24,269,520,30)];self.timesField.placeholderString=@"09:30, 11:00, 14:00, 16:00";[v addSubview:self.timesField];
        [v addSubview:[self label:@"按 Mac 当前时区每天提醒；休眠期间可能延迟。通知声音、横幅和专注模式由系统设置控制。最多支持 32 个时间点。" frame:NSMakeRect(24,211,520,49) font:12]];
        [self button:@"保存提醒设置" action:@selector(saveWater:) frame:NSMakeRect(24,166,160,32) parent:v];
        [self button:@"发送测试通知" action:@selector(testWater:) frame:NSMakeRect(194,166,160,32) parent:v];
        self.statusField=[self label:@"" frame:NSMakeRect(24,114,520,45) font:12];[v addSubview:self.statusField];
        [v addSubview:[self label:@"文件夹：只保存原目录入口。桌面文件夹可隐藏图标，其他位置不改动；可随时恢复显示。" frame:NSMakeRect(24,55,520,49) font:12]];
        [self button:@"打开文件夹集中管理" action:@selector(showFolders:) frame:NSMakeRect(24,14,220,32) parent:v];[self.settingsWindow center];
    }
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    self.enabled.state=[d boolForKey:EnabledKey]?NSControlStateValueOn:NSControlStateValueOff;
    self.timesField.stringValue=[d stringForKey:TimeKey]?:@"09:30, 11:00, 14:00, 16:00";
    [self refreshStatus];[self.settingsWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)refreshStatus {
    [[UNUserNotificationCenter currentNotificationCenter]getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s){dispatch_async(dispatch_get_main_queue(),^{
        BOOL enabled=[NSUserDefaults.standardUserDefaults boolForKey:EnabledKey];
        if(s.authorizationStatus==UNAuthorizationStatusDenied)self.statusField.stringValue=@"系统通知未允许。请在“系统设置 → 通知”中允许 Widgetify 的通知。";
        else if(s.authorizationStatus==UNAuthorizationStatusNotDetermined)self.statusField.stringValue=@"尚未请求通知权限；开启并保存或发送测试通知时，系统会询问。";
        else self.statusField.stringValue=enabled?@"每日提醒已开启。保存后按所填时间发送通知。":@"每日提醒已关闭。";
    });}];
}
- (void)authorize:(void(^)(BOOL))completion {
    [[UNUserNotificationCenter currentNotificationCenter]requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        if(error || !granted){Message(@"通知尚未开启",error.localizedDescription?:@"请在“系统设置 → 通知”中允许 Widgetify 的通知，再重试。");completion(NO);[self refreshStatus];}else completion(YES);
    });}];
}
- (void)saveWater:(id)sender {
    NSString *error=nil;NSArray *times=ParseTimes(self.timesField.stringValue,&error);
    if(!times){Message(@"请检查提醒时间",error);return;}
    NSString *normalized=[times componentsJoinedByString:@", "];BOOL on=self.enabled.state==NSControlStateValueOn;
    void(^save)(void)=^{NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setObject:normalized forKey:TimeKey];[d setBool:on forKey:EnabledKey];self.timesField.stringValue=normalized;[self reschedule];[self refreshStatus];};
    if(on)[self authorize:^(BOOL granted){if(granted)save();}];else save();
}
- (void)reschedule {
    UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
    NSString *timeText=[NSUserDefaults.standardUserDefaults stringForKey:TimeKey]?:@"09:30, 11:00, 14:00, 16:00";
    NSArray *times=ParseTimes(timeText,NULL);BOOL enabled=[NSUserDefaults.standardUserDefaults boolForKey:EnabledKey];
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests){
        NSMutableArray *remove=[NSMutableArray array];for(UNNotificationRequest *r in requests)if([r.identifier hasPrefix:NoticePrefix])[remove addObject:r.identifier];[center removePendingNotificationRequestsWithIdentifiers:remove];
        if(!enabled || !times)return;
        for(NSString *time in times){NSArray *parts=[time componentsSeparatedByString:@":"];NSDateComponents *dc=[NSDateComponents new];dc.hour=[parts[0]integerValue];dc.minute=[parts[1]integerValue];
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];content.title=@"该喝点水了";content.body=@"休息一下，喝一杯水吧。喝完可以在喝水组件中记录。";content.sound=UNNotificationSound.defaultSound;
            UNCalendarNotificationTrigger *trigger=[UNCalendarNotificationTrigger triggerWithDateMatchingComponents:dc repeats:YES];
            [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:[NoticePrefix stringByAppendingString:time] content:content trigger:trigger] withCompletionHandler:^(NSError *error){if(error)dispatch_async(dispatch_get_main_queue(),^{self.statusField.stringValue=[@"提醒保存失败：" stringByAppendingString:error.localizedDescription];});}];
        }
    }];
}
- (void)testWater:(id)sender {
    [self authorize:^(BOOL granted){if(!granted)return;UNMutableNotificationContent *content=[UNMutableNotificationContent new];content.title=@"喝水提醒测试";content.body=@"提醒已送达。你可以在增强设置中调整每日时间。";content.sound=UNNotificationSound.defaultSound;
        [[UNUserNotificationCenter currentNotificationCenter]addNotificationRequest:[UNNotificationRequest requestWithIdentifier:@"custom.water.test" content:content trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:3 repeats:NO]] withCompletionHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{self.statusField.stringValue=error?error.localizedDescription:@"测试通知已安排，将在约 3 秒后发送。";});}];
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)n withCompletionHandler:(void(^)(UNNotificationPresentationOptions))completion {
    if([n.request.identifier hasPrefix:@"custom.water."])completion(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionSound|UNNotificationPresentationOptionList);
    else if([self.previousDelegate respondsToSelector:_cmd])[self.previousDelegate userNotificationCenter:center willPresentNotification:n withCompletionHandler:completion];
    else completion(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void(^)(void))completion {
    if([response.notification.request.identifier hasPrefix:@"custom.water."]){dispatch_async(dispatch_get_main_queue(),^{[self showSettings:nil];});completion();}
    else if([self.previousDelegate respondsToSelector:_cmd])[self.previousDelegate userNotificationCenter:center didReceiveNotificationResponse:response withCompletionHandler:completion];else completion();
}
- (void)saveFolders { [NSUserDefaults.standardUserDefaults setObject:self.folders forKey:FolderKey];[NSUserDefaults.standardUserDefaults synchronize]; }
- (NSURL *)urlFor:(NSMutableDictionary *)entry {
    NSString *key=entry[@"path"];NSURL *url=self.activeURLs[key];if(url)return url;
    NSData *data=entry[@"bookmark"];BOOL stale=NO;
    url=[NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:NULL];
    if(!url)return nil;
    [url startAccessingSecurityScopedResource];self.activeURLs[key]=url;
    if(stale){NSData *fresh=[url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(fresh)entry[@"bookmark"]=fresh;}
    return url;
}
- (void)loadFolders {
    NSArray *saved=[NSUserDefaults.standardUserDefaults arrayForKey:FolderKey]?:@[];
    for(NSDictionary *d in saved)if([d[@"bookmark"]isKindOfClass:NSData.class] && [d[@"path"]isKindOfClass:NSString.class]){NSMutableDictionary *entry=[d mutableCopy];[self.folders addObject:entry];NSURL *u=[self urlFor:entry];
        if(u && [entry[@"hiddenByUs"]boolValue] && !OnDesktop(u,DesktopURL())){if([u setResourceValue:@NO forKey:NSURLIsHiddenKey error:NULL])entry[@"hiddenByUs"]=@NO;}
    }[self saveFolders];
}
- (void)showFolders:(id)sender {
    if(!self.folderWindow){
        self.folderWindow=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,620,350) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
        self.folderWindow.title=[NSString stringWithFormat:@"文件夹集中管理 · %@",CurrentVersion()];self.folderWindow.releasedWhenClosed=NO;self.folderWindow.hidesOnDeactivate=NO;self.folderWindow.minSize=NSMakeSize(570,300);
        self.folderWindow.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
        NSView *v=self.folderWindow.contentView;
        NSTextField *hint=[self label:@"双击打开原文件夹。桌面来源自动隐藏图标；其他来源不改动。" frame:NSMakeRect(16,306,585,27) font:12];hint.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;[v addSubview:hint];
        NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(16,90,588,210)];scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;scroll.hasVerticalScroller=YES;
        self.table=[[NSTableView alloc]initWithFrame:scroll.bounds];self.table.rowHeight=30;self.table.dataSource=self;self.table.delegate=self;self.table.target=self;self.table.doubleAction=@selector(openFolder:);
        [self.table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        for(NSArray *spec in @[@[@"name",@"文件夹",@170],@[@"path",@"原始路径",@290],@[@"state",@"桌面图标",@100]]){NSTableColumn *c=[[NSTableColumn alloc]initWithIdentifier:spec[0]];c.title=spec[1];c.width=[spec[2]doubleValue];[self.table addTableColumn:c];}
        scroll.documentView=self.table;[v addSubview:scroll];
        NSArray *titles=@[@"添加文件夹…",@"打开",@"恢复显示",@"隐藏桌面图标",@"移除管理"];
        SEL actions[]={@selector(addFolder:),@selector(openFolder:),@selector(restoreFolder:),@selector(hideFolder:),@selector(removeFolder:)};
        CGFloat x=12;for(int i=0;i<5;i++){CGFloat w=i==0?130:(i==3?130:98);NSButton *b=[self button:titles[i] action:actions[i] frame:NSMakeRect(x,46,w,32) parent:v];b.autoresizingMask=NSViewMaxYMargin;x+=w;}
        NSTextField *note=[self label:@"移除管理只移除入口并恢复图标，不删除原文件夹。" frame:NSMakeRect(16,10,450,30) font:11];note.autoresizingMask=NSViewWidthSizable|NSViewMaxYMargin;[v addSubview:note];NSButton *dock=[self button:@"放到桌面" action:@selector(dockFolders:) frame:NSMakeRect(484,10,120,30) parent:v];dock.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;if(![self.folderWindow setFrameUsingName:@"WidgetifyCustomFolders"])[self.folderWindow center];[self.folderWindow setFrameAutosaveName:@"WidgetifyCustomFolders"];
    }
    self.folderWindow.level=NSNormalWindowLevel;[self.table reloadData];[self.folderWindow makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)dockFolders:(id)sender {self.folderWindow.level=CGWindowLevelForKey(kCGDesktopIconWindowLevel)+1;[self.folderWindow orderFront:nil];}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table {return self.folders.count;}
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSMutableDictionary *entry=self.folders[row];NSURL *url=[self urlFor:entry];
    if([column.identifier isEqual:@"name"])return url.lastPathComponent?:[entry[@"path"]lastPathComponent];
    if([column.identifier isEqual:@"path"])return url.path?:entry[@"path"];
    if(!url)return @"无法访问";
    return OnDesktop(url,DesktopURL())?(IsHidden(url)?@"已隐藏":@"显示中"):@"保持原样";
}
- (NSMutableDictionary *)selected {NSInteger row=self.table.selectedRow;return row>=0 && row<self.folders.count?self.folders[row]:nil;}
- (void)addFolder:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"选择集中管理的原文件夹";panel.message=@"桌面文件夹仅隐藏桌面图标；其他位置的文件夹不修改路径或显示。";panel.prompt=@"添加管理";panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=YES;panel.resolvesAliases=NO;panel.directoryURL=DesktopURL();
    if([panel runModal]!=NSModalResponseOK)return;
    [self addURLs:panel.URLs];
}
- (NSDragOperation)tableView:(NSTableView *)table validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    [table setDropRow:-1 dropOperation:NSTableViewDropAbove];return NSDragOperationLink;
}
- (BOOL)tableView:(NSTableView *)table acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    NSArray *urls=[info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES,NSPasteboardURLReadingContentsConformToTypesKey:@[@"public.folder"]}];
    if(!urls.count)return NO;[self addURLs:urls];return YES;
}
- (void)addURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *failures=[NSMutableArray array];
    for(NSURL *url in urls){
        NSNumber *isDirectory=nil;[url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];if(!isDirectory.boolValue){[failures addObject:[url.lastPathComponent stringByAppendingString:@"：这里只接受文件夹。"]];continue;}
        BOOL duplicate=NO;for(NSMutableDictionary *e in self.folders)if([([self urlFor:e].path?:e[@"path"])isEqualToString:url.path]){duplicate=YES;break;}if(duplicate)continue;
        NSNumber *symlink=nil;[url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:NULL];if(symlink.boolValue){[failures addObject:[url.lastPathComponent stringByAppendingString:@"：请直接选择原文件夹，而非符号链接。"]];continue;}
        NSError *error=nil;NSData *bookmark=[url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        if(!bookmark){[failures addObject:[NSString stringWithFormat:@"%@：%@",url.lastPathComponent,error.localizedDescription]];continue;}
        [url startAccessingSecurityScopedResource];NSMutableDictionary *entry=[@{@"path":url.path,@"bookmark":bookmark,@"hiddenByUs":@NO}mutableCopy];self.activeURLs[url.path]=url;
        // Persist a recovery record before changing the visibility flag.
        [self.folders addObject:entry];[self saveFolders];
        if(OnDesktop(url,DesktopURL()) && !IsHidden(url)){
            entry[@"hiddenByUs"]=@YES;[self saveFolders];
            if(![url setResourceValue:@YES forKey:NSURLIsHiddenKey error:&error]){entry[@"hiddenByUs"]=@NO;[failures addObject:[NSString stringWithFormat:@"%@ 已添加，但隐藏失败：%@",url.lastPathComponent,error.localizedDescription]];}
        }
    }
    [self saveFolders];[self.table reloadData];if(failures.count)Message(@"部分文件夹需要处理",[failures componentsJoinedByString:@"\n"]);
}
- (void)openFolder:(id)sender {NSMutableDictionary *entry=[self selected];if(!entry)return;NSURL *url=[self urlFor:entry];if(!url || ![NSWorkspace.sharedWorkspace openURL:url])Message(@"无法打开文件夹",@"原文件夹可能已移动、删除或失去访问权限。请重新添加。");}
- (BOOL)restore:(NSMutableDictionary *)entry {
    if(![entry[@"hiddenByUs"]boolValue])return YES;
    NSURL *url=[self urlFor:entry];NSError *error=nil;
    if(!url || ![url setResourceValue:@NO forKey:NSURLIsHiddenKey error:&error]){Message(@"未能恢复显示",error.localizedDescription?:@"无法访问原文件夹。管理记录已保留，请重新授权后恢复。");return NO;}
    entry[@"hiddenByUs"]=@NO;[self saveFolders];return YES;
}
- (void)restoreFolder:(id)sender {NSMutableDictionary *e=[self selected];if(e)[self restore:e];[self.table reloadData];}
- (void)hideFolder:(id)sender {
    NSMutableDictionary *e=[self selected];if(!e)return;NSURL *url=[self urlFor:e];
    if(!url || !OnDesktop(url,DesktopURL())){Message(@"保持原样",@"只有原路径直接位于桌面的文件夹才隐藏图标，其他位置不会改动。");return;}
    if(!IsHidden(url)){e[@"hiddenByUs"]=@YES;[self saveFolders];NSError *error=nil;if(![url setResourceValue:@YES forKey:NSURLIsHiddenKey error:&error]){e[@"hiddenByUs"]=@NO;Message(@"隐藏失败",error.localizedDescription);}}
    [self saveFolders];[self.table reloadData];
}
- (void)removeFolder:(id)sender {
    NSMutableDictionary *e=[self selected];if(!e)return;if(![self restore:e])return;
    NSURL *url=self.activeURLs[e[@"path"]];[url stopAccessingSecurityScopedResource];[self.activeURLs removeObjectForKey:e[@"path"]];[self.folders removeObjectIdenticalTo:e];[self saveFolders];[self.table reloadData];
}
@end

#ifndef ENHANCEMENTS_TEST
__attribute__((constructor))static void LoadEnhancements(void){dispatch_async(dispatch_get_main_queue(),^{
    // Original SwiftUI/AppKit menus can be replaced after launch. Keep the
    // application-menu entries repaired; initialization itself runs once.
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[[WidgetifyEnhancements shared]install];}];
});}
#else
int main(void){@autoreleasepool {
    NSString *error=nil;
    NSCAssert(([ParseTimes(@"9:30，11:00, 09:30\n16:00",&error)isEqual:@[@"09:30",@"11:00",@"16:00"]]),@"Normalization");
    for(NSString *bad in @[@"24:00",@"12:60",@"-1:30",@"9:3",@"",@"12:00abc",@"09:00:00"])NSCAssert(ParseTimes(bad,&error)==nil,@"Invalid time accepted");
    NSURL *desktop=[NSURL fileURLWithPath:@"/example/Desktop" isDirectory:YES];
    NSCAssert(OnDesktop([NSURL fileURLWithPath:@"/example/Desktop/Folder"],desktop),@"Desktop folder");
    NSCAssert(!OnDesktop([NSURL fileURLWithPath:@"/example/Documents/Folder"],desktop),@"Outside folder");
    NSCAssert(!OnDesktop([NSURL fileURLWithPath:@"/example/DesktopOther/Folder"],desktop),@"Prefix collision");
    NSCAssert(!OnDesktop([NSURL fileURLWithPath:@"/example/Desktop/Parent/Nested"],desktop),@"Nested folder must not disappear inside parent");
    for(NSString *time in ParseTimes(@"00:00, 09:30, 23:59",NULL)){NSArray *parts=[time componentsSeparatedByString:@":"];NSDateComponents *components=[NSDateComponents new];components.hour=[parts[0]integerValue];components.minute=[parts[1]integerValue];UNCalendarNotificationTrigger *trigger=[UNCalendarNotificationTrigger triggerWithDateMatchingComponents:components repeats:YES];NSCAssert(trigger.nextTriggerDate!=nil && trigger.repeats,@"Daily trigger");}
    NSLog(@"PASS: time validation, deduplication, desktop boundary checks and daily calendar triggers.");
}return 0;}
#endif
