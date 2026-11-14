#import <AppKit/AppKit.h>
FOUNDATION_EXPORT BOOL WidgetifyIsDesktopChild(NSURL *url,NSURL *desktop);

// Visibility is attached to the original widget's saved references. This class
// never moves a source directory or replaces the original icon renderer.
@interface OriginalFolderBridge : NSObject
@property(nonatomic,readonly) NSString *status;
@property(nonatomic,readonly) NSURL *entryURL;
- (NSArray<NSDictionary *> *)referencesForWidget:(NSString *)identifier;
- (void)synchronizeWithHiding:(BOOL)enabled;
- (void)restoreAll;
- (BOOL)revealOriginalWidget;
@end
