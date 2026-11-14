#import <AppKit/AppKit.h>
@class OriginalFolderBridge;
@protocol ComponentSettingsDelegate
- (void)previewWater:(NSDictionary *)config context:(NSDictionary *)context window:(NSWindow *)window;
- (void)folderOptionsChanged;
@end
FOUNDATION_EXPORT NSString *WidgetifyWaterKey(NSString *identifier);
FOUNDATION_EXPORT NSString *WidgetifyFolderHideKey(NSString *identifier);
FOUNDATION_EXPORT NSDictionary *WidgetifyWaterConfiguration(NSString *identifier);
FOUNDATION_EXPORT NSView *WidgetifySettingsView(NSDictionary *context,NSWindow *window,OriginalFolderBridge *folders,id<ComponentSettingsDelegate> delegate);
