#import "DirectoryReferences.h"
#import "ComponentIntegration.h"
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const LinksKey=@"custom.references.links.v1";
static NSRecursiveLock *Lock;
static NSMutableDictionary *Pending;
static NSMutableArray<NSURL*> *AccessURLs;
static NSMutableDictionary<NSString*,NSValue*> *DropImplementations;
static NSString *Key(NSURL *u){return u.URLByStandardizingPath.path;}
static BOOL OwnedLink(NSString *path,NSDictionary *record){
    struct stat st;if(lstat(path.fileSystemRepresentation,&st)!=0||!S_ISLNK(st.st_mode)||st.st_ino!=[record[@"inode"]unsignedLongLongValue]||st.st_dev!=[record[@"device"]unsignedLongLongValue])return NO;
    NSString *target=[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:path error:NULL];return [target isEqual:record[@"source"]];
}
static BOOL ReferenceInsteadOfMove(NSURL *source,NSURL *destination,BOOL *handled,NSError **error){
    [Lock lock];NSDictionary *request=Pending[Key(source)];
    if(!request || [request[@"expires"]timeIntervalSinceNow]<=0){[Lock unlock];*handled=NO;return NO;}
    *handled=YES;struct stat before;
    if(lstat(source.fileSystemRepresentation,&before)!=0||!S_ISDIR(before.st_mode)){
        if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:@{NSLocalizedDescriptionKey:@"原目录已变化，未执行搬移。"}];[Lock unlock];return NO;
    }
    if([Key(source)isEqual:Key(destination)]){[Lock unlock];return YES;}
    NSMutableDictionary *links=[[NSUserDefaults.standardUserDefaults dictionaryForKey:LinksKey]mutableCopy]?:[NSMutableDictionary new];
    NSDictionary *old=links[Key(destination)];
    if(old && OwnedLink(Key(destination),old) && [old[@"source"]isEqual:Key(source)]){[Lock unlock];return YES;}
    BOOL ok=[NSFileManager.defaultManager createSymbolicLinkAtURL:destination withDestinationURL:source error:error];
    if(ok){
        struct stat link;ok=lstat(destination.fileSystemRepresentation,&link)==0&&S_ISLNK(link.st_mode);
        if(ok)ok=lchflags(destination.fileSystemRepresentation,link.st_flags|UF_HIDDEN)==0;
        struct stat after;if(ok)ok=lstat(source.fileSystemRepresentation,&after)==0&&after.st_ino==before.st_ino&&after.st_dev==before.st_dev&&after.st_flags==before.st_flags;
        if(ok){lstat(destination.fileSystemRepresentation,&link);links[Key(destination)]=@{@"source":Key(source),@"bookmark":request[@"bookmark"],@"inode":@(link.st_ino),@"device":@(link.st_dev),@"created":NSDate.date};[NSUserDefaults.standardUserDefaults setObject:links forKey:LinksKey];[NSUserDefaults.standardUserDefaults synchronize];[Pending removeObjectForKey:Key(source)];}
        else{
            NSString *actual=[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:destination.path error:NULL];if([actual isEqual:source.path])unlink(destination.fileSystemRepresentation);
            if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:@{NSLocalizedDescriptionKey:@"无法建立受管理的目录引用，原目录未搬移。"}];
        }
    }
    [Lock unlock];return ok;
}
static BOOL(*MoveURL)(id,SEL,NSURL*,NSURL*,NSError**);
static BOOL(*MovePath)(id,SEL,NSString*,NSString*,NSError**);
static BOOL(*CopyURL)(id,SEL,NSURL*,NSURL*,NSError**);
static BOOL(*CopyPath)(id,SEL,NSString*,NSString*,NSError**);
static BOOL MoveURLHook(id self,SEL cmd,NSURL*s,NSURL*d,NSError**e){BOOL handled=NO;BOOL ok=ReferenceInsteadOfMove(s,d,&handled,e);return handled?ok:MoveURL(self,cmd,s,d,e);}
static BOOL MovePathHook(id self,SEL cmd,NSString*s,NSString*d,NSError**e){BOOL handled=NO;BOOL ok=ReferenceInsteadOfMove([NSURL fileURLWithPath:s],[NSURL fileURLWithPath:d],&handled,e);return handled?ok:MovePath(self,cmd,s,d,e);}
static BOOL CopyURLHook(id self,SEL cmd,NSURL*s,NSURL*d,NSError**e){BOOL handled=NO;BOOL ok=ReferenceInsteadOfMove(s,d,&handled,e);return handled?ok:CopyURL(self,cmd,s,d,e);}
static BOOL CopyPathHook(id self,SEL cmd,NSString*s,NSString*d,NSError**e){BOOL handled=NO;BOOL ok=ReferenceInsteadOfMove([NSURL fileURLWithPath:s],[NSURL fileURLWithPath:d],&handled,e);return handled?ok:CopyPath(self,cmd,s,d,e);}
static void(*RevealURLs)(id,SEL,NSArray*);
static void Reveal(id self,SEL cmd,NSArray *urls){NSMutableArray *targets=[NSMutableArray new];for(NSURL*u in urls){NSDictionary*r=WidgetifyOriginalDirectoryReference(u);[targets addObject:r?[NSURL fileURLWithPath:r[@"source"]]:u];}RevealURLs(self,cmd,targets);}
static BOOL ProtectedDrop(NSView *view,SEL cmd,id<NSDraggingInfo> info){
    Class cls=view.class;IMP original=NULL;[Lock lock];while(cls && !original){original=DropImplementations[NSStringFromClass(cls)].pointerValue;cls=class_getSuperclass(cls);}[Lock unlock];
    if(!original)return NO;
    NSDictionary *context=WidgetifyContext(view.window);
    if([context[@"kind"]isEqual:@"folder"]){
        NSArray *urls=[info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];NSMutableArray *directories=[NSMutableArray new];
        for(NSURL*u in urls){struct stat st;if(u.hasDirectoryPath||(lstat(u.fileSystemRepresentation,&st)==0&&S_ISDIR(st.st_mode)))[directories addObject:u];}
        NSError *error=nil;if(directories.count && !WidgetifyProtectDirectoryImports(directories,&error)){
            if(![NSStringFromClass([info class])isEqual:@"DirectoryImportInfo"]){NSAlert*a=[NSAlert new];a.messageText=@"请使用“添加文件夹引用”";a.informativeText=@"原目录未搬移。请从此组件的文件夹管理设置选择目录，以便取得访问权限。";[a addButtonWithTitle:@"好"];[a runModal];}return NO;
        }
    }
    return ((BOOL(*)(id,SEL,id))original)(view,cmd,info);
}
static void InstallDropClass(Class cls){
    if(![NSStringFromClass(cls)containsString:@"PlatformDraggingDestinationView"])return;[Lock lock];if(DropImplementations[NSStringFromClass(cls)]){[Lock unlock];return;}
    Method method=class_getInstanceMethod(cls,@selector(performDragOperation:));if(!method){[Lock unlock];return;}IMP original=method_getImplementation(method);if(original==(IMP)ProtectedDrop){[Lock unlock];return;}
    DropImplementations[NSStringFromClass(cls)]=[NSValue valueWithPointer:original];
    if(!class_addMethod(cls,@selector(performDragOperation:),(IMP)ProtectedDrop,method_getTypeEncoding(method)))method_setImplementation(class_getInstanceMethod(cls,@selector(performDragOperation:)),(IMP)ProtectedDrop);
    [Lock unlock];
}
static void(*RegisterTypes)(id,SEL,NSArray*);
static void Register(id self,SEL cmd,NSArray *types){RegisterTypes(self,cmd,types);if(types.count)InstallDropClass([self class]);}
void WidgetifyInstallDirectoryReferences(void){static dispatch_once_t once;dispatch_once(&once,^{
    Lock=[NSRecursiveLock new];Pending=[NSMutableDictionary new];AccessURLs=[NSMutableArray new];DropImplementations=[NSMutableDictionary new];
    for(NSDictionary *record in [NSUserDefaults.standardUserDefaults dictionaryForKey:LinksKey].allValues){NSData*data=record[@"bookmark"];if(![data isKindOfClass:NSData.class])continue;NSURL*u=[NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithSecurityScope|NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];if(u){[u startAccessingSecurityScopedResource];[AccessURLs addObject:u];}}
    MoveURL=(void*)method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(moveItemAtURL:toURL:error:)),(IMP)MoveURLHook);
    MovePath=(void*)method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(moveItemAtPath:toPath:error:)),(IMP)MovePathHook);
    CopyURL=(void*)method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(copyItemAtURL:toURL:error:)),(IMP)CopyURLHook);
    CopyPath=(void*)method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(copyItemAtPath:toPath:error:)),(IMP)CopyPathHook);
    RegisterTypes=(void*)method_setImplementation(class_getInstanceMethod(NSView.class,@selector(registerForDraggedTypes:)),(IMP)Register);
    RevealURLs=(void*)method_setImplementation(class_getInstanceMethod(NSWorkspace.class,@selector(activateFileViewerSelectingURLs:)),(IMP)Reveal);
});}
BOOL WidgetifyProtectDirectoryImports(NSArray<NSURL *> *urls,NSError **error){
    WidgetifyInstallDirectoryReferences();NSMutableDictionary *requests=[NSMutableDictionary new];
    for(NSURL *url in urls){[Lock lock];BOOL existing=[Pending[Key(url)][@"expires"]timeIntervalSinceNow]>0;[Lock unlock];if(existing)continue;struct stat st;[url startAccessingSecurityScopedResource];if(lstat(url.fileSystemRepresentation,&st)!=0||!S_ISDIR(st.st_mode))return NO;
        NSData *bookmark=[url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:error];if(!bookmark)return NO;
        [Lock lock];[AccessURLs addObject:url];[Lock unlock];
        requests[Key(url)]=@{@"bookmark":bookmark,@"expires":[NSDate dateWithTimeIntervalSinceNow:60]};
    }
    [Lock lock];[Pending addEntriesFromDictionary:requests];[Lock unlock];return YES;
}
NSDictionary *WidgetifyOriginalDirectoryReference(NSURL *url){
    WidgetifyInstallDirectoryReferences();[Lock lock];NSMutableDictionary *records=[[NSUserDefaults.standardUserDefaults dictionaryForKey:LinksKey]mutableCopy];NSDictionary *record=records[Key(url)];
    if(!record){for(NSString *path in [records.allKeys copy]){if(OwnedLink(Key(url),records[path])){record=records[path];records[Key(url)]=record;[records removeObjectForKey:path];[NSUserDefaults.standardUserDefaults setObject:records forKey:LinksKey];break;}}}
    if(record && !OwnedLink(Key(url),record))record=nil;[Lock unlock];return record;
}
void WidgetifyCleanDirectoryReferences(NSSet<NSString*>*referenced){
    WidgetifyInstallDirectoryReferences();[Lock lock];NSDictionary *snapshot=[NSUserDefaults.standardUserDefaults dictionaryForKey:LinksKey]?:@{};[Lock unlock];
    NSMutableArray *removed=[NSMutableArray new];
    for(NSString *path in snapshot){NSDictionary*r=snapshot[path];if([referenced containsObject:path]||[r[@"created"]timeIntervalSinceNow]>-60)continue;
        if(OwnedLink(path,r) && ![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:NULL error:NULL])continue;
        [removed addObject:path];
    }
    [Lock lock];NSMutableDictionary *records=[[NSUserDefaults.standardUserDefaults dictionaryForKey:LinksKey]mutableCopy]?:[NSMutableDictionary new];
    for(NSString *path in removed)if([records[path]isEqual:snapshot[path]])[records removeObjectForKey:path];
    if(removed.count)[NSUserDefaults.standardUserDefaults setObject:records forKey:LinksKey];
    NSString *stored=[NSUserDefaults.standardUserDefaults stringForKey:@"documentSaveFolderPath"];id decoded=stored?[NSJSONSerialization JSONObjectWithData:[stored dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL]:nil;NSURL *storage=[decoded isKindOfClass:NSString.class]?[NSURL URLWithString:decoded]:nil;
    for(NSString *path in [Pending.allKeys copy]){
        BOOL imported=[referenced containsObject:path] && [[path stringByDeletingLastPathComponent]isEqual:storage.path];
        if(imported||[Pending[path][@"expires"]timeIntervalSinceNow]<=0)[Pending removeObjectForKey:path];
    }[Lock unlock];
}
