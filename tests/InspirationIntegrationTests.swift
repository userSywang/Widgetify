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
        let saved: [[String: Any]] = [["id": "retained", "screenID": "old", "screenFrame": [[0,0],[1920,1080]], "winFrame": [[1560,690],[344,179.5]], "settings": ["keep": true]]]
        let savedData = try JSONSerialization.data(withJSONObject: saved)
        let recovered = try recoveredScreenLayout(savedData, screens: [("new", screen)])!
        var expected = saved; expected[0]["screenID"] = "new"
        let recoveredValues = try JSONSerialization.jsonObject(with: recovered) as! NSArray
        precondition(recoveredValues.isEqual(to: expected))
        let unchanged = try recoveredScreenLayout(recovered, screens: [("new", screen)])
        precondition(unchanged == nil)
        let missing = try recoveredScreenLayout(savedData, screens: [])
        let multiple = try recoveredScreenLayout(savedData, screens: [("new",screen),("other",screen)])
        precondition(missing == nil && multiple == nil)
        var mixed = saved; var second = saved[0]; second["screenID"] = "other"; mixed.append(second)
        let mixedData = try JSONSerialization.data(withJSONObject: mixed)
        let disconnected = try recoveredScreenLayout(mixedData, screens: [("new",screen)])
        precondition(disconnected == nil)
        let smaller = try recoveredScreenLayout(savedData, screens: [("new", CGRect(x:0,y:0,width:1280,height:720))])!
        let smallerWidgets = try JSONSerialization.jsonObject(with: smaller) as! [[String:Any]]
        let smallerFrame = smallerWidgets[0]["winFrame"] as! [[Double]]
        precondition(smallerFrame[0][0] == 936 && smallerFrame[0][1] == 540.5)
        do { _ = try recoveredScreenLayout(Data("invalid".utf8), screens: [("new",screen)]); preconditionFailure() } catch {}
        print("PASS: screen recovery preserves metadata, is idempotent, clamps resized displays and skips ambiguous/disconnected displays")
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
