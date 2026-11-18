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
static NSArray *Options(NSDictionary *schema) {return schema[@"properties"][@"分类"][@"select"][@"options"]?:@[];}
static void Require(BOOL value,NSString *flag) {Report[flag]=@(value);SaveReport();if(!value)[NSException raise:@"PropertyTrialVerificationFailed" format:@"%@",flag];}
static void Run(void) {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *root=[support URLByAppendingPathComponent:([NSBundle.mainBundle.infoDictionary[@"WidgetifyNotionKeepTestPage"]boolValue]?@"NotionPropertyReview":@"NotionPropertyTrial")];
    ReportURL=[root URLByAppendingPathComponent:@"report.json"];
    if([NSFileManager.defaultManager fileExistsAtPath:ReportURL.path])return;
    Report=[@{@"status":@"started",@"pid":@(NSProcessInfo.processInfo.processIdentifier),@"executable":NSBundle.mainBundle.executablePath,@"transport":@"in-process NSURLSession HTTPS REST",@"requests":[NSMutableArray new]}mutableCopy];SaveReport();
    BOOL keep=[NSBundle.mainBundle.infoDictionary[@"WidgetifyNotionKeepTestPage"]boolValue];NSString *originalCategoryID=nil;
    __block NSString *pageID=nil;NSString *category=[@"API验证分类-" stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:8]];NSString *sourceID=nil;
    @try {
        NSURL *credential=[root URLByAppendingPathComponent:@"token.txt"];Token=[[NSString stringWithContentsOfURL:credential encoding:NSUTF8StringEncoding error:nil]stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];[NSFileManager.defaultManager removeItemAtURL:credential error:nil];
        if(!Token.length)[NSException raise:@"MissingCredential" format:@"Missing credential"];
        NSDictionary *config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"config.json"]] options:0 error:nil];sourceID=config[@"dataSourceID"];
        Session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        NSString *schemaPath=[@"data_sources/" stringByAppendingString:sourceID];NSDictionary *schema=Request(@"GET",schemaPath,nil);NSArray *existing=Options(schema);Require(existing.count>0,@"readExistingCategories");originalCategoryID=existing.firstObject[@"id"];
        NSDate *added=NSDate.date;NSDictionary *entry=@{@"text":@"Widgetify 属性与时间追加测试",@"context":@"仅用于 API 可行性验证",@"createdAt":@(added.timeIntervalSinceReferenceDate),@"additions":@[]};
        NSMutableDictionary *payload=[Payload(entry,sourceID,entry[@"text"],nil)mutableCopy];NSMutableDictionary *props=[payload[@"properties"]mutableCopy];props[@"分类"]=@{@"select":@{@"id":existing.firstObject[@"id"]}};props[@"优秀级"]=@{@"select":@{@"name":@"中优先级"}};props[@"状态"]=@{@"status":@{@"name":@"未开始"}};payload[@"properties"]=props;
        NSDictionary *page=Request(@"POST",@"pages",payload);pageID=page[@"id"];Report[@"pageID"]=pageID;SaveReport();NSString *path=[@"pages/" stringByAppendingString:pageID];
        NSDictionary *read=Request(@"GET",path,nil);NSDictionary *properties=read[@"properties"];
        Require([properties[@"分类"][@"select"][@"id"]isEqual:existing.firstObject[@"id"]],@"reuseExistingCategory");
        Require([properties[@"优秀级"][@"select"][@"name"]isEqual:@"中优先级"]&&[properties[@"状态"][@"status"][@"name"]isEqual:@"未开始"],@"initialDefaults");
        NSString *dateStart=properties[@"日期"][@"date"][@"start"];Require([dateStart isEqual:props[@"日期"][@"date"][@"start"]],@"automaticCreationDate");
        Request(@"PATCH",path,@{@"properties":@{@"分类":@{@"select":@{@"name":category}}}});
        NSDictionary *schemaAfter=Request(@"GET",schemaPath,nil);BOOL found=NO;for(NSDictionary *option in Options(schemaAfter))if([option[@"name"]isEqual:category])found=YES;Require(found,@"createdCategoryVisibleInSchema");
        // Simulate independent Notion edits, then ensure appending never resets them.
        Request(@"PATCH",path,@{@"properties":@{@"优秀级":@{@"select":@{@"name":@"高优先级"}},@"状态":@{@"status":@{@"name":@"进行中"}}}});
        NSMutableArray *expected=[NSMutableArray new];NSMutableArray *times=[NSMutableArray new];NSDateFormatter *stamp=[NSDateFormatter new];stamp.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];stamp.dateFormat=@"yyyy/MM/dd HH:mm:ss";stamp.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
        for(NSString *text in @[@"第一次保存的补充",@"第二次保存的补充"]){
            NSString *time=[stamp stringFromDate:NSDate.date];[times addObject:time];[expected addObject:time];[expected addObject:text];
            NSDictionary *heading=@{@"object":@"block",@"type":@"heading_3",@"heading_3":@{@"rich_text":Rich(time)}};
            Request(@"PATCH",[NSString stringWithFormat:@"blocks/%@/children",pageID],@{@"children":@[heading,Paragraph(text)]});
            NSString *details=[NSString stringWithFormat:@"%@\n\n%@",entry[@"context"],[expected componentsJoinedByString:@"\n"]];
            Request(@"PATCH",path,@{@"properties":@{@"详情":@{@"rich_text":Rich(details)}}});
        }
        NSDictionary *blocks=Request(@"GET",[NSString stringWithFormat:@"blocks/%@/children?page_size=100",pageID],nil);NSMutableArray *lines=[NSMutableArray new];for(NSDictionary *block in blocks[@"results"])[lines addObject:Plain(block[block[@"type"]][@"rich_text"]?:@[])];
        Require([lines count]==6 && [lines[0]isEqual:entry[@"text"]] && [lines[1]isEqual:entry[@"context"]] && [[lines subarrayWithRange:NSMakeRange(2,4)]isEqual:expected],@"appendOrderAndOriginalPreserved");
        Require([times[0]compare:times[1]]==NSOrderedAscending,@"appendTimestampsAscending");
        read=Request(@"GET",path,nil);properties=read[@"properties"];
        Require([properties[@"日期"][@"date"][@"start"]isEqual:dateStart],@"originalDatePreserved");
        Require([properties[@"状态"][@"status"][@"name"]isEqual:@"进行中"]&&[properties[@"优秀级"][@"select"][@"name"]isEqual:@"高优先级"],@"remoteStatusPriorityPreserved");
        Require([Plain(properties[@"详情"][@"rich_text"])containsString:expected.lastObject],@"detailsPropertyUpdated");
        Require([properties[@"分类"][@"select"][@"name"]isEqual:category],@"newCategoryAssigned");Report[@"verificationPassed"]=@YES;
    }@catch(NSException *error){Report[@"failureType"]=error.name;Report[@"verificationPassed"]=@NO;}
    @finally {
        @try {
            if(pageID && keep){ Request(@"PATCH",[@"pages/" stringByAppendingString:pageID],@{@"properties":@{@"分类":@{@"select":@{@"id":originalCategoryID}}}}); NSDictionary *retained=Request(@"GET",[@"pages/" stringByAppendingString:pageID],nil); Report[@"testPageRetained"]=@(![retained[@"in_trash"]boolValue]);Report[@"pageURL"]=retained[@"url"]?:@""; }
            if(pageID && !keep){Request(@"PATCH",[@"pages/" stringByAppendingString:pageID],@{@"in_trash":@YES});NSDictionary *read=Request(@"GET",[@"pages/" stringByAppendingString:pageID],nil);Report[@"testPageTrashed"]=@([read[@"in_trash"]boolValue]);}
            if(sourceID){
                NSString *path=[@"data_sources/" stringByAppendingString:sourceID];NSDictionary *schema=Request(@"GET",path,nil);NSMutableArray *retained=[NSMutableArray new];BOOL own=NO;
                for(NSDictionary *option in Options(schema)){if([option[@"name"]isEqual:category])own=YES;else[retained addObject:@{@"id":option[@"id"],@"name":option[@"name"],@"color":option[@"color"]?:@"default"}];}
                if(own)Request(@"PATCH",path,@{@"properties":@{@"分类":@{@"select":@{@"options":retained}}}});
                NSDictionary *check=Request(@"GET",path,nil);BOOL absent=YES;for(NSDictionary *o in Options(check))if([o[@"name"]isEqual:category])absent=NO;Report[@"temporaryCategoryRemoved"]=@(absent);
            }
        }@catch(NSException *error){Report[@"cleanupFailureType"]=error.name;}
        Report[@"status"]=([Report[@"verificationPassed"]boolValue]&&(keep?[Report[@"testPageRetained"]boolValue]:[Report[@"testPageTrashed"]boolValue])&&[Report[@"temporaryCategoryRemoved"]boolValue])?@"complete":@"failed";
        Token=nil;[Session finishTasksAndInvalidate];SaveReport();
    }
}
__attribute__((constructor)) static void LoadPropertyTrial(void) {
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
        if(![NSBundle.mainBundle.infoDictionary[@"WidgetifyIntegrationTest"]boolValue]||![NSBundle.mainBundle.infoDictionary[@"WidgetifyNotionPropertyTrial"]boolValue])return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{Run();}});
    }});
}
