#import <AppKit/AppKit.h>
FOUNDATION_EXPORT void WidgetifyInstallDirectoryReferences(void);
FOUNDATION_EXPORT BOOL WidgetifyProtectDirectoryImports(NSArray<NSURL *> *urls,NSError **error);
FOUNDATION_EXPORT NSDictionary *WidgetifyOriginalDirectoryReference(NSURL *url);
FOUNDATION_EXPORT void WidgetifyCleanDirectoryReferences(NSSet<NSString *> *referencedPaths);
