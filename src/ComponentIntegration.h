#import <AppKit/AppKit.h>
FOUNDATION_EXPORT NSDictionary *WidgetifyContext(NSWindow *window);
FOUNDATION_EXPORT void WidgetifyInstallComponentIntegration(id provider);
FOUNDATION_EXPORT BOOL WidgetifyOpenOriginalSettings(NSWindow *window);
FOUNDATION_EXPORT BOOL WidgetifyImportDirectoryReferences(NSWindow *window,NSArray<NSURL *> *urls);
