import AppKit
@main struct InspirationIntegrationTests {
    static func main() throws {
        let screen=NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let old:[[String:Any]]=[["id":"existing", "screenID":"test", "winFrame":[[24,673],[344,359]], "untouched":["path":"/original/folder", "value":42]]]
        let original=try JSONSerialization.data(withJSONObject:old)
        let next=try inspirationLayout(original,screenID:"test",screen:screen)
        let widgets=try JSONSerialization.jsonObject(with:next) as! [[String:Any]]
        precondition(widgets.count==2 && NSDictionary(dictionary:widgets[0]).isEqual(to:old[0]))
        let added=widgets[1]
        precondition(added["id"] as? String==inspirationComponentID && added["name"] as? String=="widget_name_shortcuts")
        let frame=added["winFrame"] as! [[Double]]
        precondition(!NSRect(x:frame[0][0],y:frame[0][1],width:frame[1][0],height:frame[1][1]).intersects(NSRect(x:24,y:673,width:344,height:359)))
        let again=try inspirationLayout(next,screenID:"test",screen:screen)
        let againValues = try JSONSerialization.jsonObject(with:again) as! NSArray
        precondition(againValues.isEqual(to:widgets))
        do { _=try inspirationLayout(Data("invalid".utf8),screenID:"test",screen:screen);preconditionFailure("Corrupt layout must be rejected") } catch {}
        let fresh=try inspirationLayout(nil,screenID:"test",screen:screen)
        let freshValues = try JSONSerialization.jsonObject(with:fresh) as! NSArray
        precondition(freshValues.count==1)
        if CommandLine.arguments.count > 1 {
            let path = URL(fileURLWithPath: CommandLine.arguments[1])
            let bytes = try Data(contentsOf:path)
            let originals = try JSONSerialization.jsonObject(with:bytes) as! [[String:Any]]
            let result = try inspirationLayout(bytes,screenID:"test",screen:screen)
            let merged = try JSONSerialization.jsonObject(with:result) as! [[String:Any]]
            precondition(merged.count == originals.count+1)
            for (a,b) in zip(originals,merged) { precondition(NSDictionary(dictionary:a).isEqual(to:b)) }
            let after = try Data(contentsOf:path)
            precondition(after == bytes)
            print("PASS: read-only real layout check preserves all \(originals.count) original widgets")
        }
        print("PASS: integration preserves original widget metadata, avoids overlap, adds once, supports fresh layouts and rejects corrupt layouts")
    }
}
