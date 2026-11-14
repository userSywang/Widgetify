#import "OriginalFolderBridge.h"
#import "ComponentSettings.h"
#import "DirectoryReferences.h"
#import <pwd.h>
#import <unistd.h>
#import <sys/stat.h>

static NSString *const RecordsKey=@"custom.enhancements.folders.v1";
static NSURL *DesktopDirectory(void) {
    struct passwd *user=getpwuid(getuid());
    return user?[[NSURL fileURLWithPath:[NSString stringWithUTF8String:user->pw_dir] isDirectory:YES]URLByAppendingPathComponent:@"Desktop" isDirectory:YES]:nil;
}
BOOL WidgetifyIsDesktopChild(NSURL *url,NSURL *desktop) {
    return [url.URLByDeletingLastPathComponent.URLByStandardizingPath.URLByResolvingSymlinksInPath.path isEqual:desktop.URLByResolvingSymlinksInPath.path];
}
static BOOL HiddenFlag(NSURL *url) {
    struct stat info;return lstat(url.fileSystemRepresentation,&info)==0 && (info.st_flags&UF_HIDDEN)!=0;
}
static BOOL Directory(NSURL *url) {
    struct stat info;return lstat(url.fileSystemRepresentation,&info)==0 && S_ISDIR(info.st_mode);
}
static NSString *PathKey(NSURL *url) {return url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path;}

static BOOL AliasMatches(NSURL *alias,NSString *path){
    NSNumber *isAlias=nil;[alias getResourceValue:&isAlias forKey:NSURLIsAliasFileKey error:NULL];if(!isAlias.boolValue)return NO;
    NSURL *target=[NSURL URLByResolvingAliasFileAtURL:alias options:NSURLBookmarkResolutionWithoutUI error:NULL];
    return target && [PathKey(target)isEqual:PathKey([NSURL fileURLWithPath:path])];
}
static NSString *StableSuffix(NSString *path){uint32_t hash=2166136261;const unsigned char *bytes=(void*)path.UTF8String;while(*bytes){hash^=*bytes++;hash*=16777619;}return [NSString stringWithFormat:@"%08x",hash];}
@interface OriginalFolderBridge ()
@property(nonatomic,readwrite) NSString *status;
@property(nonatomic,readwrite) NSURL *entryURL;
@property NSMutableArray<NSMutableDictionary *> *records;
@property NSMutableDictionary<NSString *,NSURL *> *accessURLs;
@property NSArray<NSDictionary *> *widgets;
@property NSDate *readyAfter;
@property NSURL *parentAccessURL;
@property NSMutableSet<NSString*> *referencedPaths;
@end

@implementation OriginalFolderBridge
- (instancetype)init {
    if((self=[super init])){
        self.records=[NSMutableArray new];self.accessURLs=[NSMutableDictionary new];self.widgets=@[];
        self.readyAfter=[NSDate dateWithTimeIntervalSinceNow:4];
        for(NSDictionary *record in [NSUserDefaults.standardUserDefaults arrayForKey:RecordsKey])
            if([record isKindOfClass:NSDictionary.class] && [record[@"path"]isKindOfClass:NSString.class])[self.records addObject:[record mutableCopy]];
        NSData *parent=[NSUserDefaults.standardUserDefaults dataForKey:@"documentSaveFolderBookmark"];
        if(parent){self.parentAccessURL=[NSURL URLByResolvingBookmarkData:parent options:NSURLBookmarkResolutionWithSecurityScope|NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];[self.parentAccessURL startAccessingSecurityScopedResource];}
        self.status=@"正在读取原文档整理组件…";
    }return self;
}
- (NSURL *)resolve:(NSURL *)source bookmark:(NSData *)bookmark {
    NSString *key=[NSString stringWithFormat:@"%@:%lu",source.absoluteString,(unsigned long)bookmark.hash];
    NSURL *cached=self.accessURLs[key];if(cached)return cached;
    NSURL *url=bookmark?[NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope|NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL]:source;
    if(url){[url startAccessingSecurityScopedResource];self.accessURLs[key]=url;}return url;
}
- (void)persist:(NSArray *)records {
    if(![self.records isEqualToArray:records]){
        self.records=[records mutableCopy];[NSUserDefaults.standardUserDefaults setObject:self.records forKey:RecordsKey];[NSUserDefaults.standardUserDefaults synchronize];
    }
}
- (NSArray<NSDictionary *> *)referencesForWidget:(NSString *)identifier {
    NSURL *documents=[[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"widgetify" isDirectory:YES];
    NSURL *list=[documents URLByAppendingPathComponent:identifier];NSData *data=[NSData dataWithContentsOfURL:list];
    if(!data)return [NSFileManager.defaultManager fileExistsAtPath:list.path]?nil:@[];
    NSArray *paths=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if(![paths isKindOfClass:NSArray.class])return nil;
    NSData *archive=[NSData dataWithContentsOfURL:[documents URLByAppendingPathComponent:[identifier stringByAppendingString:@"_bookmark"]]];
    NSDictionary *bookmarks=nil;
    if(archive){NSSet *classes=[NSSet setWithObjects:NSDictionary.class,NSMutableDictionary.class,NSURL.class,NSData.class,NSString.class,nil];bookmarks=[NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:archive error:NULL];if(!bookmarks)return nil;}
    NSMutableArray *result=[NSMutableArray new];
    for(id value in paths){
        if(![value isKindOfClass:NSString.class])return nil;NSURL *source=[NSURL URLWithString:value];if(!source.isFileURL)continue;
        [self.referencedPaths addObject:source.URLByStandardizingPath.path];NSDictionary *managed=WidgetifyOriginalDirectoryReference(source);
        NSData *bookmark=managed[@"bookmark"]?:bookmarks[source]?:bookmarks[value];NSURL *original=managed?[NSURL fileURLWithPath:managed[@"source"] isDirectory:YES]:source;NSURL *url=[self resolve:original bookmark:bookmark];
        if(!url)return nil;if(!Directory(url))continue;
        NSMutableDictionary *entry=[@{@"path":url.path,@"url":url}mutableCopy];if(bookmark)entry[@"bookmark"]=bookmark;[result addObject:entry];
    }return result;
}
- (NSArray<NSDictionary *> *)readOriginalReferences {
    NSURL *support=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Widgetify/autosaved.widgetlist4"];
    NSData *data=[NSData dataWithContentsOfURL:support];NSArray *snapshot=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;if(![snapshot isKindOfClass:NSArray.class])return nil;
    self.referencedPaths=[NSMutableSet new];NSMutableArray *widgets=[NSMutableArray new];NSMutableDictionary *references=[NSMutableDictionary new];
    NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet];
    for(NSDictionary *widget in snapshot){
        if(![widget isKindOfClass:NSDictionary.class]||![widget[@"name"]isEqual:@"widget_name_folder"])continue;
        NSString *identifier=widget[@"id"];if(![identifier isKindOfClass:NSString.class]||identifier.length!=32||[identifier rangeOfCharacterFromSet:bad].location!=NSNotFound)return nil;
        NSArray *items=[self referencesForWidget:identifier];if(!items)return nil;[widgets addObject:widget];
        id hide=[NSUserDefaults.standardUserDefaults objectForKey:WidgetifyFolderHideKey(identifier)];BOOL enabled=hide?[hide boolValue]:[NSUserDefaults.standardUserDefaults boolForKey:@"custom.enhancements.originalFolders.hideDesktop"];
        for(NSDictionary *item in items){NSMutableDictionary *entry=[item mutableCopy];NSString *key=PathKey(item[@"url"]);entry[@"hide"]=@(enabled||[references[key][@"hide"]boolValue]);references[key]=entry;}
    }self.widgets=widgets;WidgetifyCleanDirectoryReferences(self.referencedPaths);return [references.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){return[a[@"path"]compare:b[@"path"]];}];
}
- (NSSet<NSString *> *)updateFinderEntry:(NSArray<NSDictionary *> *)references {
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableSet *ready=[NSMutableSet new];
    if(!self.entryURL){
        for(NSUInteger index=0;index<20;index++){
            NSString *name=index==0?@"文件夹入口":(index==1?@"Widgetify 文件夹入口":[NSString stringWithFormat:@"Widgetify 文件夹入口 %lu",(unsigned long)index]);
            NSURL *candidate=[DesktopDirectory() URLByAppendingPathComponent:name isDirectory:YES];
            NSDictionary *marker=[NSDictionary dictionaryWithContentsOfURL:[candidate URLByAppendingPathComponent:@".widgetify-entries.plist"]];
            if([marker[@"owner"]isEqual:@"local.widgetify.custom"] || ![fm fileExistsAtPath:candidate.path]){self.entryURL=candidate;break;}
        }
    }
    BOOL existed=self.entryURL && [fm fileExistsAtPath:self.entryURL.path];
    if(existed && ![[NSDictionary dictionaryWithContentsOfURL:[self.entryURL URLByAppendingPathComponent:@".widgetify-entries.plist"]][@"owner"]isEqual:@"local.widgetify.custom"]){self.entryURL=nil;return ready;}
    if(!self.entryURL||![fm createDirectoryAtURL:self.entryURL withIntermediateDirectories:NO attributes:nil error:NULL]){
        if(!Directory(self.entryURL))return ready;
    }
    NSURL *manifestURL=[self.entryURL URLByAppendingPathComponent:@".widgetify-entries.plist"];
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfURL:manifestURL];NSDictionary *old=[saved[@"entries"]isKindOfClass:NSDictionary.class]?saved[@"entries"]:@{};
    NSMutableDictionary *next=[NSMutableDictionary new],*counts=[NSMutableDictionary new];BOOL changed=NO;
    for(NSDictionary*r in references){NSString*name=[r[@"path"]lastPathComponent];counts[name]=@([counts[name]integerValue]+1);}
    for(NSDictionary *r in references){
        NSURL *target=r[@"url"];if([PathKey(target)isEqual:PathKey(self.entryURL)])continue;
        NSString *name=[counts[target.lastPathComponent]integerValue]>1?[NSString stringWithFormat:@"%@-%@.alias",target.lastPathComponent,StableSuffix(target.path)]:[target.lastPathComponent stringByAppendingString:@".alias"];
        NSURL *alias=[self.entryURL URLByAppendingPathComponent:name];BOOL exists=[fm fileExistsAtPath:alias.path];
        if(exists && ![old[name]isEqual:target.path]){
            // Never replace a pre-existing or user-replaced item we don't own.
            if(!old[name])continue;
            if(!AliasMatches(alias,old[name]))continue;
            if(![fm trashItemAtURL:alias resultingItemURL:NULL error:NULL])continue;exists=NO;
        }
        if(!exists){NSData *bookmark=[target bookmarkDataWithOptions:NSURLBookmarkCreationSuitableForBookmarkFile includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(!bookmark||![NSURL writeBookmarkData:bookmark toURL:alias options:0 error:NULL])continue;changed=YES;}
        if(!AliasMatches(alias,target.path))continue;next[name]=target.path;[ready addObject:PathKey(target)];
    }
    for(NSString *name in old){
        if(next[name]||![name.lastPathComponent isEqual:name])continue;
        NSURL *alias=[self.entryURL URLByAppendingPathComponent:name];
        if(AliasMatches(alias,old[name])){[fm trashItemAtURL:alias resultingItemURL:NULL error:NULL];changed=YES;}
    }
    if(changed||![old isEqual:next]||!saved){
        [@{@"owner":@"local.widgetify.custom",@"entries":next}writeToURL:manifestURL atomically:YES];
        NSMutableString *index=[@"这些是原文件夹的访达替身，不是内容副本。Widgetify 未运行时仍可打开。正常退出会恢复原桌面图标。\n\n" mutableCopy];
        for(NSString *name in [[next allKeys]sortedArrayUsingSelector:@selector(compare:)])[index appendFormat:@"%@\n%@\n\n",name,next[name]];
        [index writeToURL:[self.entryURL URLByAppendingPathComponent:@"原文件夹位置.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return ready;
}
- (BOOL)restoreRecord:(NSMutableDictionary *)record {
    if(![record[@"hiddenByUs"]boolValue])return YES;
    NSURL *url=[self resolve:[NSURL fileURLWithPath:record[@"path"]] bookmark:record[@"bookmark"]];
    if(!url || !Directory(url))return NO;
    if(![url setResourceValue:@NO forKey:NSURLIsHiddenKey error:NULL] || HiddenFlag(url))return NO;
    record[@"hiddenByUs"]=@NO;return YES;
}
- (void)synchronizeWithHiding:(BOOL)enabled {
    if([self.readyAfter timeIntervalSinceNow]>0)return;
    NSArray *references=[self readOriginalReferences];
    if(!references){self.status=@"原组件正在保存数据，稍后自动重试。";return;}
    NSSet *accessible=[self updateFinderEntry:references];
    NSMutableDictionary *old=[NSMutableDictionary new];
    for(NSDictionary *record in self.records){NSURL *url=[self resolve:[NSURL fileURLWithPath:record[@"path"]] bookmark:record[@"bookmark"]];if(url)old[PathKey(url)]=[record mutableCopy];}
    NSMutableArray *next=[NSMutableArray new];NSUInteger hidden=0,errors=0;
    for(NSDictionary *source in references){
        NSURL *url=source[@"url"];NSString *key=PathKey(url);
        NSMutableDictionary *record=old[key]?:[@{@"path":url.path,@"hiddenByUs":@NO}mutableCopy];
        [old removeObjectForKey:key];record[@"path"]=url.path;
        if(source[@"bookmark"])record[@"bookmark"]=source[@"bookmark"];
        if([source[@"hide"]boolValue] && WidgetifyIsDesktopChild(url,DesktopDirectory()) && ![PathKey(url)isEqual:PathKey(self.entryURL)] && [accessible containsObject:key]){
            if(!HiddenFlag(url)){
                // Persist recovery intent before changing the on-disk flag.
                record[@"hiddenByUs"]=@YES;NSMutableArray *recovery=[self.records mutableCopy];[recovery addObject:record];[self persist:recovery];
                if(![url setResourceValue:@YES forKey:NSURLIsHiddenKey error:NULL] || !HiddenFlag(url)){record[@"hiddenByUs"]=@NO;errors++;}
            }
            if(HiddenFlag(url))hidden++;
        }else{if([source[@"hide"]boolValue] && ![accessible containsObject:key])errors++;if(![self restoreRecord:record])errors++;}
        [next addObject:record];
    }
    for(NSMutableDictionary *record in old.allValues)if(![self restoreRecord:record]){errors++;[next addObject:record];}
    [self persist:next];
    self.status=self.widgets.count?[NSString stringWithFormat:@"原卡片中 %lu 个文件夹；桌面隐藏 %lu 个。%@",(unsigned long)references.count,(unsigned long)hidden,errors?@"部分入口或目录不可用，相关目录不会继续隐藏。":@"退出恢复图标；未运行时可用桌面文件夹入口。"]:@"尚未添加原“文档整理”组件；请在组件库添加。";
}
- (void)restoreAll {
    NSMutableArray *next=[NSMutableArray new];NSUInteger errors=0;
    for(NSDictionary *old in self.records){NSMutableDictionary *record=[old mutableCopy];if(![self restoreRecord:record])errors++;[next addObject:record];}
    [self persist:next];self.status=errors?@"部分目录无法访问，恢复记录已保留。":@"已恢复由本功能隐藏的桌面图标；原卡片入口不删除。";
}
- (BOOL)revealOriginalWidget {
    [self readOriginalReferences];NSWindow *best=nil;CGFloat bestScore=CGFLOAT_MAX;
    for(NSDictionary *widget in self.widgets){
        NSArray *frame=widget[@"winFrame"];if(![frame isKindOfClass:NSArray.class] || frame.count!=2)continue;
        NSRect expected=NSMakeRect([frame[0][0]doubleValue],[frame[0][1]doubleValue],[frame[1][0]doubleValue],[frame[1][1]doubleValue]);
        for(NSWindow *window in NSApp.windows){
            if(![NSStringFromClass(window.class)containsString:@"WidgetWindow"])continue;
            NSRect actual=window.frame;CGFloat score=fabs(actual.origin.x-expected.origin.x)+fabs(actual.origin.y-expected.origin.y)+fabs(actual.size.width-expected.size.width)+fabs(actual.size.height-expected.size.height);
            if(score<bestScore){best=window;bestScore=score;}
        }
    }
    if(best && bestScore<150){[best makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];return YES;}
    id<NSApplicationDelegate> delegate=NSApp.delegate;
    if([delegate respondsToSelector:@selector(applicationShouldHandleReopen:hasVisibleWindows:)])[delegate applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];
    return NO;
}
@end
