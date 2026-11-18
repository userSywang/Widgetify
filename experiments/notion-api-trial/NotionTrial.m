#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// Isolated experiment only. This module is never loaded by the installed app.
// Requests run inside the cloned Widgetify process, not a chat connector.
static NSMutableDictionary *Report;
static NSURL *ReportURL;
static NSString *Token;
static NSURLSession *Session;
static void SaveReport(void) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:Report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:ReportURL options:NSDataWritingAtomic error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:ReportURL.path error:nil];
}
static NSDictionary *Request(NSString *method,NSString *path,NSDictionary *body) {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.notion.com/v1/" stringByAppendingString:path]]];
    request.HTTPMethod=method;request.timeoutInterval=25;
    [request setValue:[@"Bearer " stringByAppendingString:Token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"2026-03-11" forHTTPHeaderField:@"Notion-Version"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if(body)request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);
    __block NSDictionary *object;__block NSInteger status=0,networkError=0;
    NSURLSessionDataTask *task=[Session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        status=[(NSHTTPURLResponse*)response statusCode];networkError=error.code;
        id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if([parsed isKindOfClass:NSDictionary.class])object=parsed;
        dispatch_semaphore_signal(semaphore);
    }];[task resume];
    BOOL timedOut=dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))!=0;
    if(timedOut)[task cancel];
    // Never persist headers, credential strings, response bodies or note text.
    NSMutableDictionary *event=[@{@"method":method,@"path":path,@"status":@(status)} mutableCopy];
    if(networkError)event[@"networkError"]=@(networkError);if(timedOut)event[@"timeout"]=@YES;
    [Report[@"requests"] addObject:event];SaveReport();
    if(timedOut||status<200||status>=300||!object) {
        [NSException raise:@"NotionTrialRequestFailed" format:@"HTTP %ld",(long)status];
    }
    [NSThread sleepForTimeInterval:0.4];return object;
}
static NSArray *Rich(NSString *text) {
    NSMutableArray *items=[NSMutableArray new];
    for(NSUInteger start=0;start<text.length;) {
        NSRange range=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(start,MIN((NSUInteger)900,text.length-start))];
        [items addObject:@{@"type":@"text",@"text":@{@"content":[text substringWithRange:range]}}];start=NSMaxRange(range);
    }return items;
}
static NSDictionary *Paragraph(NSString *text) {return @{@"object":@"block",@"type":@"paragraph",@"paragraph":@{@"rich_text":Rich(text)}};}
static NSString *Plain(NSArray *rich) {
    NSMutableString *s=[NSMutableString new];for(NSDictionary *part in rich)[s appendString:part[@"plain_text"]?:part[@"text"][@"content"]?:@""];return s;
}
static NSDictionary *Payload(NSDictionary *entry,NSString *sourceID,NSString *title,NSString *probeID) {
    NSMutableArray *children=[NSMutableArray arrayWithObject:Paragraph(entry[@"text"])];
    if([entry[@"context"] length])[children addObject:Paragraph(entry[@"context"])];
    for(NSDictionary *addition in entry[@"additions"])[children addObject:Paragraph(addition[@"text"])];
    if(probeID)[children addObject:Paragraph([@"Widgetify direct API probe: " stringByAppendingString:probeID])];
    NSDateFormatter *date=[NSDateFormatter new];date.dateFormat=@"yyyy-MM-dd";date.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];date.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    NSString *day=[date stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:[entry[@"createdAt"]doubleValue]]];
    NSMutableArray *details=[NSMutableArray new];if([entry[@"context"]length])[details addObject:entry[@"context"]];for(NSDictionary *a in entry[@"additions"])[details addObject:a[@"text"]];
    return @{@"parent":@{@"type":@"data_source_id",@"data_source_id":sourceID},@"properties":@{@"创意":@{@"title":Rich(title)},@"日期":@{@"date":@{@"start":day}},@"详情":@{@"rich_text":Rich([details componentsJoinedByString:@"\n\n"])}},@"children":children};
}
static void Verify(NSDictionary *page,NSDictionary *entry,NSString *title) {
    if(![Plain(page[@"properties"][@"创意"][@"title"])isEqual:title])[NSException raise:@"NotionTrialVerificationFailed" format:@"Title mismatch"];
    NSString *pageID=page[@"id"];
    NSDictionary *content=Request(@"GET",[NSString stringWithFormat:@"blocks/%@/children?page_size=100",pageID],nil);
    NSMutableString *body=[NSMutableString new];
    for(NSDictionary *block in content[@"results"]) {NSDictionary *value=block[block[@"type"]];[body appendString:Plain(value[@"rich_text"]?:@[])];[body appendString:@"\n"];}
    if(![body containsString:entry[@"text"]])[NSException raise:@"NotionTrialVerificationFailed" format:@"Original text mismatch"];
    for(NSDictionary *a in entry[@"additions"])if(![body containsString:a[@"text"]])[NSException raise:@"NotionTrialVerificationFailed" format:@"Addition mismatch"];
}
static void Run(void) {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root=[support URLByAppendingPathComponent:@"NotionTrial"];
    ReportURL=[root URLByAppendingPathComponent:@"report.json"];
    if([NSFileManager.defaultManager fileExistsAtPath:ReportURL.path])return; // Never retry a potentially successful create blindly.
    Report=[@{@"status":@"started",@"pid":@(NSProcessInfo.processInfo.processIdentifier),@"executable":NSBundle.mainBundle.executablePath,@"bundleID":NSBundle.mainBundle.bundleIdentifier,@"transport":@"in-process NSURLSession HTTPS REST",@"requests":[NSMutableArray new],@"created":[NSMutableArray new],@"skipped":[NSMutableArray new]}mutableCopy];SaveReport();
    @try {
        NSURL *credential=[root URLByAppendingPathComponent:@"token.txt"];
        Token=[[NSString stringWithContentsOfURL:credential encoding:NSUTF8StringEncoding error:nil]stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSFileManager.defaultManager removeItemAtURL:credential error:nil];
        if(!Token.length)[NSException raise:@"NotionTrialMissingCredential" format:@"No credential"];
        NSDictionary *config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"config.json"]] options:0 error:nil];
        NSString *sourceID=config[@"dataSourceID"];
        NSDictionary *document=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[support URLByAppendingPathComponent:@"NotionTrial/ideas-v1.json"]] options:0 error:nil];
        NSMutableArray *active=[NSMutableArray new];for(NSDictionary *e in document[@"entries"])if(![e[@"archived"]boolValue] && (!e[@"deletedAt"]||e[@"deletedAt"]==NSNull.null))[active addObject:e];
        if(!active.count||!sourceID.length)[NSException raise:@"NotionTrialMissingInput" format:@"Missing snapshot or target"];
        Session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        NSDictionary *identity=Request(@"GET",@"users/me",nil);Report[@"apiBotID"]=identity[@"id"];
        NSDictionary *schema=Request(@"GET",[@"data_sources/" stringByAppendingString:sourceID],nil);
        if(![schema[@"properties"][@"创意"][@"type"]isEqual:@"title"])[NSException raise:@"NotionTrialSchemaMismatch" format:@"Unexpected title property"];
        for(NSDictionary *entry in active) {
            NSDictionary *query=Request(@"POST",[NSString stringWithFormat:@"data_sources/%@/query",sourceID],@{@"filter":@{@"property":@"创意",@"title":@{@"equals":entry[@"text"]}},@"page_size":@2});
            NSArray *existing=query[@"results"];
            if(existing.count){[Report[@"skipped"]addObject:@{@"localID":entry[@"id"],@"pageID":existing[0][@"id"]}];SaveReport();continue;}
            NSDictionary *page=Request(@"POST",@"pages",Payload(entry,sourceID,entry[@"text"],nil));
            [Report[@"created"]addObject:@{@"localID":entry[@"id"],@"pageID":page[@"id"]}];SaveReport();
            Verify(Request(@"GET",[@"pages/" stringByAppendingString:page[@"id"]],nil),entry,entry[@"text"]);
        }
        // Existing chat-imported records are kept untouched. A distinct temporary
        // row exercises a real write and readback, then goes to recoverable Trash.
        if(![Report[@"created"]count]) {
            NSDictionary *entry=active.firstObject;NSString *probe=NSUUID.UUID.UUIDString;
            NSString *title=[@"Widgetify API 测试 · " stringByAppendingString:entry[@"text"]];
            NSDictionary *page=Request(@"POST",@"pages",Payload(entry,sourceID,title,probe));
            Report[@"probePageID"]=page[@"id"];Report[@"probeURL"]=page[@"url"];SaveReport();
            NSDictionary *read=Request(@"GET",[@"pages/" stringByAppendingString:page[@"id"]],nil);Verify(read,entry,title);
            if(![read[@"created_by"][@"id"]isEqual:identity[@"id"]])[NSException raise:@"NotionTrialVerificationFailed" format:@"Creator mismatch"];
            Report[@"writeReadbackVerified"]=@YES;SaveReport();
            Request(@"PATCH",[@"pages/" stringByAppendingString:page[@"id"]],@{@"in_trash":@YES});
            NSDictionary *trashed=Request(@"GET",[@"pages/" stringByAppendingString:page[@"id"]],nil);
            Report[@"probeTrashed"]=@([trashed[@"in_trash"]boolValue]);
            if(![Report[@"probeTrashed"]boolValue])[NSException raise:@"NotionTrialCleanupFailed" format:@"Test row still visible"];
        }else Report[@"writeReadbackVerified"]=@YES;
        Report[@"sourceCount"]=@(active.count);Report[@"status"]=@"complete";
    }@catch(NSException *exception){Report[@"status"]=@"failed";Report[@"failureType"]=exception.name;}
    Token=nil;[Session finishTasksAndInvalidate];SaveReport();
}
__attribute__((constructor)) static void LoadNotionTrial(void) {
    // Do not touch Foundation or NSBundle before the host's sandbox and main
    // application have initialized. Only enqueue work during dylib loading.
    dispatch_async(dispatch_get_main_queue(),^{ @autoreleasepool {
        if(![NSBundle.mainBundle.infoDictionary[@"WidgetifyIntegrationTest"]boolValue]||![NSBundle.mainBundle.infoDictionary[@"WidgetifyNotionAPITrial"]boolValue])return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{Run();}});
    }});
}
#ifdef NOTION_TRIAL_TEST
int main(void) { @autoreleasepool {
    NSMutableString *text=[NSMutableString new];for(int i=0;i<1200;i++)[text appendString:@"中文🌱"];
    NSArray *rich=Rich(text);NSCAssert([Plain(rich)isEqual:text],@"Chunking must preserve Unicode");
    for(NSDictionary *part in rich)NSCAssert([part[@"text"][@"content"]length]<=2000,@"Rich-text segment exceeds API limit");
    NSDictionary *entry=@{@"id":@"local-test",@"text":@"</script>原文",@"context":@"背景",@"createdAt":@816574942,@"additions":@[@{@"text":@"补充"}]};
    NSDictionary *body=Payload(entry,@"source",entry[@"text"],nil);
    NSCAssert([body[@"parent"][@"data_source_id"]isEqual:@"source"],@"Must target data source");
    NSCAssert([Plain(body[@"properties"][@"创意"][@"title"])isEqual:entry[@"text"]],@"Original title changed");
    NSCAssert([body[@"children"]count]==3,@"Missing context or addition");
    NSCAssert(!body[@"Authorization"],@"Credentials must not enter payload");
    puts("PASS: direct REST payload preserves original text, context, supplements and Unicode; credential excluded from JSON body");
}return 0;}
#endif
