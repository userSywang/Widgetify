#import "ComponentIntegration.h"
#import <objc/runtime.h>
#import "DirectoryReferences.h"
extern void *WidgetifyCopyContext(void *view);
NSDictionary *WidgetifyContext(NSWindow *window){
    if(![NSStringFromClass(window.class) isEqual:@"Widgetify.WidgetWindow"] || !window.contentView)return nil;
    return CFBridgingRelease(WidgetifyCopyContext((__bridge void *)window.contentView));
}
@interface NSObject (WidgetifySettingsProvider)
- (NSView *)settingsForComponent:(NSDictionary *)context window:(NSWindow *)window;
@end
@interface ComponentSettingsContainer:NSView
@property NSView *original;
@property(weak) NSWindow *anchorWindow;
@property NSView *extension;
@property NSSegmentedControl *tabs;
@property BOOL customSelected;
@end
@implementation ComponentSettingsContainer
- (BOOL)isFlipped{return YES;}
- (void)layout{
    [super layout];CGFloat width=self.bounds.size.width,height=self.bounds.size.height;
    self.tabs.frame=NSMakeRect(12,8,MAX(0,width-24),26);
    NSRect content=NSMakeRect(0,42,width,MAX(0,height-42));self.original.frame=content;self.extension.frame=content;
}
- (void)selectTab:(id)sender{self.customSelected=self.tabs.selectedSegment==1;self.original.hidden=self.customSelected;self.extension.hidden=!self.customSelected;self.needsLayout=YES;}
@end
static id Provider;
static char ContainerKey;
static void(*OriginalShow)(id,SEL,NSRect,NSView *,NSRectEdge);
static void(*OriginalSize)(id,SEL,NSSize);
static void SetSize(NSPopover *popover,SEL cmd,NSSize size){
    ComponentSettingsContainer *container=objc_getAssociatedObject(popover,&ContainerKey);
    if(container && popover.contentViewController.view==container){CGFloat maximum=(container.anchorWindow.screen?:NSScreen.mainScreen).visibleFrame.size.height-110;size.height=MIN(MAX(size.height+42,490),MAX(490,maximum));size.width=MAX(328,size.width);}
    OriginalSize(popover,cmd,size);
}
static void Show(NSPopover *popover,SEL cmd,NSRect rect,NSView *anchor,NSRectEdge edge){
    ComponentSettingsContainer *container=objc_getAssociatedObject(popover,&ContainerKey);
    if(container && popover.contentViewController.view!=container){objc_setAssociatedObject(popover,&ContainerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);container=nil;}
    if(container && !popover.isShown){NSView *extra=[Provider settingsForComponent:WidgetifyContext(anchor.window) window:anchor.window];if(extra){[container.extension removeFromSuperview];container.extension=extra;extra.hidden=!container.customSelected;[container addSubview:extra positioned:NSWindowBelow relativeTo:container.tabs];container.needsLayout=YES;}}
    if(!container && [NSStringFromClass([popover.delegate class])containsString:@"WidgetSettingsPopoverPresenter"]){
        NSDictionary *context=WidgetifyContext(anchor.window);
        if(context && Provider){
            NSView *extra=[Provider settingsForComponent:context window:anchor.window];
            if(extra){
                NSViewController *originalController=popover.contentViewController;
                NSView *original=originalController.view;
                container=[[ComponentSettingsContainer alloc]initWithFrame:original.frame];container.anchorWindow=anchor.window;container.original=original;container.extension=extra;extra.hidden=YES;
                container.tabs=[NSSegmentedControl segmentedControlWithLabels:@[@"组件设置",[context[@"kind"]isEqual:@"water"]?@"喝水提醒":@"文件夹管理"] trackingMode:NSSegmentSwitchTrackingSelectOne target:container action:@selector(selectTab:)];container.tabs.selectedSegment=0;
                NSViewController *wrapperController=[NSViewController new];[wrapperController addChildViewController:originalController];
                [original removeFromSuperview];[container addSubview:original];[container addSubview:extra];[container addSubview:container.tabs];wrapperController.view=container;popover.contentViewController=wrapperController;
                objc_setAssociatedObject(popover,&ContainerKey,container,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSSize size=popover.contentSize;SetSize(popover,@selector(setContentSize:),size);
            }
        }
    }
    OriginalShow(popover,cmd,rect,anchor,edge);
}
void WidgetifyInstallComponentIntegration(id provider){
    Provider=provider;static dispatch_once_t once;dispatch_once(&once,^{
        OriginalShow=(void*)method_setImplementation(class_getInstanceMethod(NSPopover.class,@selector(showRelativeToRect:ofView:preferredEdge:)),(IMP)Show);
        OriginalSize=(void*)method_setImplementation(class_getInstanceMethod(NSPopover.class,@selector(setContentSize:)),(IMP)SetSize);
    });
}
extern BOOL WidgetifyInvokeSettings(void *);
BOOL WidgetifyOpenOriginalSettings(NSWindow *window){return WidgetifyInvokeSettings((__bridge void*)window.contentView);}
@interface DirectoryImportInfo:NSObject<NSDraggingInfo>
@property(weak) NSWindow *draggingDestinationWindow;
@property NSPasteboard *draggingPasteboard;
@property NSPoint draggingLocation;
@property NSDraggingFormation draggingFormation;
@property BOOL animatesToDestination;
@property NSInteger numberOfValidItemsForDrop;
@property NSArray<NSURL*> *urls;
@end
@implementation DirectoryImportInfo
- (NSDragOperation)draggingSourceOperationMask{return NSDragOperationLink|NSDragOperationCopy;}
- (NSPoint)draggedImageLocation{return self.draggingLocation;}
- (NSImage*)draggedImage{return nil;}
- (id)draggingSource{return nil;}
- (NSInteger)draggingSequenceNumber{return 987654;}
- (void)slideDraggedImageTo:(NSPoint)p{}
- (NSArray*)namesOfPromisedFilesDroppedAtDestination:(NSURL*)url{return nil;}
- (NSSpringLoadingHighlight)springLoadingHighlight{return NSSpringLoadingHighlightNone;}
- (void)resetSpringLoading{}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)options forView:(NSView*)view classes:(NSArray<Class>*)classes searchOptions:(NSDictionary*)searchOptions usingBlock:(void(^)(NSDraggingItem*,NSInteger,BOOL*))block{
    NSArray *items=[self.draggingPasteboard readObjectsForClasses:classes options:searchOptions];BOOL stop=NO;NSInteger index=0;
    for(id item in items){NSDraggingItem *drag=[[NSDraggingItem alloc]initWithPasteboardWriter:item];drag.draggingFrame=NSMakeRect(self.draggingLocation.x,self.draggingLocation.y,24,24);block(drag,index++,&stop);if(stop)break;}
}
@end
static void Destinations(NSView *view,NSMutableArray *result){if(view.registeredDraggedTypes.count)[result addObject:view];for(NSView *child in view.subviews)Destinations(child,result);}
static char ImportKey;
BOOL WidgetifyImportDirectoryReferences(NSWindow *window,NSArray<NSURL *> *urls){
    NSError *error=nil;if(!WidgetifyProtectDirectoryImports(urls,&error))return NO;
    DirectoryImportInfo*info=[DirectoryImportInfo new];info.urls=urls;info.draggingDestinationWindow=window;info.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];[info.draggingPasteboard writeObjects:urls];info.numberOfValidItemsForDrop=urls.count;
    NSView *root=window.contentView;info.draggingLocation=[root convertPoint:NSMakePoint(20,root.isFlipped?root.bounds.size.height-40:40) toView:nil];
    NSMutableArray *views=[NSMutableArray new];Destinations(root,views);BOOL accepted=NO;
    for(NSView *view in views){
        NSDragOperation operation=[view draggingEntered:info];
        if(operation && [view prepareForDragOperation:info]){accepted=[view performDragOperation:info];if(accepted){[view concludeDragOperation:info];break;}}
        [view draggingExited:info];
    }
    if(accepted){NSMutableArray *pending=objc_getAssociatedObject(window,&ImportKey);if(!pending){pending=[NSMutableArray new];objc_setAssociatedObject(window,&ImportKey,pending,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}[pending addObject:info];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{[pending removeObject:info];});}
    return accepted;
}
