#import "ComponentSettings.h"
#import "OriginalFolderBridge.h"
#import "ComponentIntegration.h"
#import "ReminderSchedule.h"
#import <objc/runtime.h>
NSString *WidgetifyWaterKey(NSString *i){return [@"custom.component." stringByAppendingFormat:@"%@.water",i];}
NSString *WidgetifyFolderHideKey(NSString *i){return [@"custom.component." stringByAppendingFormat:@"%@.folders.hideDesktop",i];}
NSDictionary *WidgetifyWaterConfiguration(NSString *i){
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:WidgetifyWaterKey(i)];
    NSMutableDictionary *c=[@{@"enabled":@NO,@"times":@"09:30, 11:00, 14:00, 16:00",@"style":@0,@"duration":@10,@"position":@0,@"sound":@YES}mutableCopy];if(saved)[c addEntriesFromDictionary:saved];return c;
}
@interface FlippedSettingsDocument:NSView
@end
@implementation FlippedSettingsDocument
- (BOOL)isFlipped{return YES;}
@end
@interface SettingsPage:NSObject
@property NSDictionary *context;
@property(weak) NSWindow *window;
@property OriginalFolderBridge *folders;
@property(weak) id<ComponentSettingsDelegate> delegate;
@property NSView *document;
@property NSTextField *times,*status;
@property NSButton *enabled,*sound,*hide;
@property NSPopUpButton *style,*duration,*position;
@property CGFloat y;
@end
@implementation SettingsPage
- (NSTextField*)text:(NSString*)s size:(CGFloat)size height:(CGFloat)height{
    NSTextField *v=[NSTextField wrappingLabelWithString:s];v.font=[NSFont systemFontOfSize:size];v.frame=NSMakeRect(18,self.y,292,height);[self.document addSubview:v];self.y+=height+8;return v;
}
- (NSButton*)button:(NSString*)s action:(SEL)action{
    NSButton*b=[NSButton buttonWithTitle:s target:self action:action];b.frame=NSMakeRect(18,self.y,292,30);[self.document addSubview:b];self.y+=38;return b;
}
- (NSButton*)toggle:(NSString*)s action:(SEL)action{
    NSButton*b=[NSButton checkboxWithTitle:s target:self action:action];b.frame=NSMakeRect(18,self.y,292,26);[self.document addSubview:b];self.y+=34;return b;
}
- (NSPopUpButton*)choices:(NSArray*)labels values:(NSArray*)values selected:(NSInteger)selected{
    NSPopUpButton *b=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,self.y,292,28) pullsDown:NO];[b addItemsWithTitles:labels];for(NSUInteger i=0;i<values.count;i++)b.itemArray[i].tag=[values[i]integerValue];[b selectItemWithTag:selected];[self.document addSubview:b];self.y+=36;return b;
}
- (NSView*)make{
    // A flipped document inside the original popover, not a separate window.
    self.document=[[FlippedSettingsDocument alloc]initWithFrame:NSMakeRect(0,0,328,800)];self.y=16;
    if([self.context[@"kind"]isEqual:@"water"]){
        NSDictionary*c=WidgetifyWaterConfiguration(self.context[@"id"]);
        [self text:@"喝水提醒" size:18 height:26];self.enabled=[self toggle:@"开启每日定时提醒" action:NULL];self.enabled.state=[c[@"enabled"]boolValue];
        [self text:@"每天的时间（24 小时制）" size:12 height:18];self.times=[[NSTextField alloc]initWithFrame:NSMakeRect(18,self.y,292,29)];self.times.stringValue=c[@"times"];[self.document addSubview:self.times];self.y+=38;
        [self text:@"弹窗样式" size:12 height:18];self.style=[self choices:@[@"跟随组件 · 卡片",@"跟随组件 · 轻提示"] values:@[@0,@1] selected:[c[@"style"]integerValue]];
        [self text:@"停留时间" size:12 height:18];self.duration=[self choices:@[@"5 秒",@"10 秒",@"20 秒",@"直到手动关闭"] values:@[@5,@10,@20,@0] selected:[c[@"duration"]integerValue]];
        [self text:@"显示位置" size:12 height:18];self.position=[self choices:@[@"组件旁边",@"当前屏幕右上角"] values:@[@0,@1] selected:[c[@"position"]integerValue]];
        self.sound=[self toggle:@"播放提醒声音" action:NULL];self.sound.state=[c[@"sound"]boolValue];
        [self button:@"保存提醒设置" action:@selector(save:)];[self button:@"立即预览所选样式" action:@selector(preview:)];
        self.status=[self text:@"预览会按所选时长关闭。每日提醒需要软件运行；不会自动增加饮水记录。" size:11 height:55];
    }else{
        [self text:@"文件夹管理" size:18 height:26];
        [self text:@"请用“添加文件夹引用”收纳目录，保留原路径。桌面目录可隐藏；其他位置不改变显示。" size:12 height:48];
        id saved=[NSUserDefaults.standardUserDefaults objectForKey:WidgetifyFolderHideKey(self.context[@"id"])];self.hide=[self toggle:@"隐藏此组件已收纳的桌面文件夹" action:@selector(hiding:)];self.hide.state=saved?[saved boolValue]:[NSUserDefaults.standardUserDefaults boolForKey:@"custom.enhancements.originalFolders.hideDesktop"];
        [self button:@"添加文件夹引用…" action:@selector(addFolders:)];
        [self button:@"恢复此组件的桌面图标" action:@selector(restore:)];
        [self button:@"打开访达文件夹入口" action:@selector(openEntry:)];
        [self text:@"正常退出会恢复图标。异常退出时，也能从桌面“文件夹入口”访问原目录。" size:11 height:48];
        self.status=[self text:self.folders.status?:@"正在读取原组件…" size:11 height:54];
        NSArray *references=[self.folders referencesForWidget:self.context[@"id"]];
        for(NSDictionary*r in references){
            NSButton*b=[self button:[@"在访达显示：" stringByAppendingString:[r[@"path"]lastPathComponent]] action:@selector(reveal:)];b.toolTip=r[@"path"];[self text:r[@"path"] size:10 height:34];
        }
    }
    self.document.frame=NSMakeRect(0,0,328,self.y+12);NSScrollView*scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,328,450)];scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;scroll.documentView=self.document;scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;objc_setAssociatedObject(scroll,@selector(make),self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return scroll;
}
- (NSDictionary*)configuration{
    NSString *error=nil;NSArray *times=WidgetifyParseTimes(self.times.stringValue,&error);if(!times){self.status.stringValue=error;return nil;}
    return @{@"enabled":@(self.enabled.state==1),@"times":[times componentsJoinedByString:@", "],@"style":@(self.style.selectedItem.tag),@"duration":@(self.duration.selectedItem.tag),@"position":@(self.position.selectedItem.tag),@"sound":@(self.sound.state==1)};
}
- (void)save:(id)sender{NSDictionary*c=[self configuration];if(!c)return;[NSUserDefaults.standardUserDefaults setObject:c forKey:WidgetifyWaterKey(self.context[@"id"])];self.times.stringValue=c[@"times"];self.status.stringValue=[c[@"enabled"]boolValue]?@"已保存，软件运行时按这些时间提醒。":@"已保存，每日提醒已关闭，仍可预览。";}
- (void)preview:(id)sender{NSDictionary*c=[self configuration];if(c){[self.delegate previewWater:c context:self.context window:self.window];self.status.stringValue=@"已显示预览，使用当前选择的样式和停留时间。";}}
- (void)hiding:(id)sender{[NSUserDefaults.standardUserDefaults setBool:self.hide.state==1 forKey:WidgetifyFolderHideKey(self.context[@"id"])];[self.delegate folderOptionsChanged];self.status.stringValue=self.folders.status;}
- (void)restore:(id)sender{self.hide.state=0;[self hiding:nil];}
- (void)addFolders:(id)sender{
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=YES;panel.prompt=@"添加引用";panel.message=@"只添加原目录入口，不移动文件夹。";
    [panel beginWithCompletionHandler:^(NSModalResponse response){if(response!=NSModalResponseOK)return;NSArray *urls=panel.URLs;NSWindow*w=self.window;NSString*i=self.context[@"id"];self.status.stringValue=@"正在更新原组件…";
        BOOL accepted=WidgetifyImportDirectoryReferences(w,urls);self.status.stringValue=accepted?@"已交给原卡片添加，请查看目录列表。":@"原卡片未接受该目录，原目录未改动。";
        [self.delegate folderOptionsChanged];
    }];
}
- (void)openEntry:(id)sender{NSURL*u=self.folders.entryURL;if(u)[NSWorkspace.sharedWorkspace openURL:u];}
- (void)reveal:(NSButton*)sender{[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:sender.toolTip]]];}
@end
NSView *WidgetifySettingsView(NSDictionary*c,NSWindow*w,OriginalFolderBridge*f,id<ComponentSettingsDelegate>d){SettingsPage*p=[SettingsPage new];p.context=c;p.window=w;p.folders=f;p.delegate=d;return[p make];}
