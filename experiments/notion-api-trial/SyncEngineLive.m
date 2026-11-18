#import <Foundation/Foundation.h>
extern void WidgetifyRunNotionEnginePreview(void);
__attribute__((constructor)) static void RunPreview(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ WidgetifyRunNotionEnginePreview(); });
}
