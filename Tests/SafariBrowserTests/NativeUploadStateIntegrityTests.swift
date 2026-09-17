import Foundation
import JavaScriptCore
import XCTest
@testable import SafariBrowser

/// These are state-integrity checks after initialization in a fresh realm with
/// genuine JavaScript intrinsics. The small DOM adapter is not evidence that a
/// hostile page's prepatched DOM/intrinsics can be isolated in Safari's realm.
final class NativeUploadStateIntegrityTests: XCTestCase {
    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(NativeUploadDOMFixture.source)
        context.evaluateScript("var beforeKeys=Object.getOwnPropertyNames(window);var matchingMetadata=[{name:'café.txt',size:17,lastModified:123456}];")
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.initializeJS(selector: "#upload", nonce: "integrity-fixture", fileName: "café.txt", fileSize: 17, modificationTimeMilliseconds: 123456, receiptToken: NativeUploadDOMFixture.receipt))?.toString(), "OK")
        context.evaluateScript("var stateKeys=Object.getOwnPropertyNames(window).filter(function(key){return beforeKeys.indexOf(key)<0;});")
        XCTAssertGreaterThan(context.evaluateScript("stateKeys.length")?.toInt32() ?? 0, 0,
                             "The attack must discover the production state binding, including non-enumerable properties")
        XCTAssertNil(context.exception)
        XCTAssertEqual(completion(context), "PENDING")
        return context
    }

    private func completion(_ context: JSContext) -> String? {
        context.evaluateScript(NativeUploadScript.completionJS(selector: "#upload", nonce: "integrity-fixture"))?.toString()
    }

    private func assertNoForgedSuccess(_ context: JSContext, attack: String, file: StaticString = #filePath, line: UInt = #line) {
        context.evaluateScript(attack)
        XCTAssertNil(context.exception, file: file, line: line)
        XCTAssertNotEqual(completion(context), NativeUploadDOMFixture.receipt, "No actual input/change delivery occurred", file: file, line: line)
        XCTAssertNil(context.exception, file: file, line: line)
        XCTAssertEqual(context.evaluateScript("input.files.length")?.toInt32(), 0, file: file, line: line)
    }

    func testDirectSnapshotMutationCannotForgeDeliveryAfterCancel() throws {
        let context = try context()
        // No browser-owned dispatch occurs: this also represents a chooser that
        // was cancelled, leaving the original input's empty FileList unchanged.
        assertNoForgedSuccess(context, attack: """
        stateKeys.forEach(function(key){
          var state=window[key];
          if(state && (typeof state==='object'||typeof state==='function'))
            Reflect.set(state,'selection',matchingMetadata);
        });
        """)
    }

    func testReplacingDiscoveredBindingCannotForgeDelivery() throws {
        let context = try context()
        assertNoForgedSuccess(context, attack: """
        stateKeys.forEach(function(key){
          Reflect.defineProperty(window,key,{configurable:true,value:{
            nonce:'integrity-fixture',doc:document,input:input,url:window.location.href,
            rejected:false,selection:matchingMetadata
          }});
        });
        """)
    }

    func testCallingExposedListenerWithTrustedLookingObjectCannotForgeDelivery() throws {
        let context = try context()
        assertNoForgedSuccess(context, attack: """
        stateKeys.forEach(function(key){
          var state=window[key];
          if(state && typeof state.listener==='function'){
            // A normal object may claim isTrusted=true, although a page-created
            // real DOM Event cannot acquire the browser's trusted-event flag.
            input.files=matchingMetadata;
            state.listener({target:input,isTrusted:true});
            input.files=[];
          }
        });
        """)
    }

    func testUntrustedDOMEventRemainsPendingWithoutTampering() throws {
        let context = try context()
        context.evaluateScript("input.files=matchingMetadata;listener({target:input,isTrusted:false});input.files=[];")
        XCTAssertEqual(completion(context), "PENDING")
        XCTAssertNil(context.exception)
    }

    func testFixtureBrowserOwnedDeliveryStillRecognized() throws {
        let context = try context()
        context.evaluateScript("input.files=matchingMetadata;listener({target:input,isTrusted:true});input.files=[];")
        XCTAssertEqual(completion(context), NativeUploadDOMFixture.receipt)
        XCTAssertNil(context.exception)
    }
    func testForgedReadReturningOKDoesNotRevealReceipt() throws {
        let context = try context()
        assertNoForgedSuccess(context, attack: """
        stateKeys.forEach(function(key){Reflect.defineProperty(window,key,{configurable:true,value:{read:function(){return 'OK';}}});});
        """)
        XCTAssertEqual(completion(context), "OK", "The native layer must reject this raw page-controlled status")
    }

    func testExposedMethodsAndQueriesDoNotDiscloseReceipt() throws {
        let context = try context()
        let sources = context.evaluateScript("stateKeys.map(function(k){return Object.getOwnPropertyNames(window[k]).map(function(p){return String(window[k][p]);}).join('\\n');}).join('\\n')")?.toString() ?? ""
        XCTAssertFalse(sources.contains(NativeUploadDOMFixture.receipt))
        XCTAssertFalse(NativeUploadScript.completionJS(selector: "#upload", nonce: "integrity-fixture").contains(NativeUploadDOMFixture.receipt))
        XCTAssertEqual(context.evaluateScript("Object.isFrozen(window[stateKeys[0]])")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("typeof window[stateKeys[0]].listener")?.toString(), "undefined")
    }

    func testWrongTrustedFileNeverReleasesReceiptEvenAfterOverwrite() throws {
        let context = try context()
        context.evaluateScript("input.files=[{name:'wrong.txt',size:17,lastModified:123456}];listener({target:input,isTrusted:true});")
        XCTAssertEqual(completion(context), "MISMATCH_NAME")
        context.evaluateScript("input.files=matchingMetadata;listener({target:input,isTrusted:true});")
        XCTAssertEqual(completion(context), "MISMATCH_NAME")
    }

    func testCapturedNativeGettersAndIntrinsicsIgnoreLaterOverrides() throws {
        let context = try context()
        context.evaluateScript("""
        input.files=[{name:'wrong.txt',size:1,lastModified:1}];
        Object.defineProperty(input,'files',{get:function(){return matchingMetadata;}});
        Object.defineProperty(File.prototype,'name',{get:function(){return 'café.txt';}});
        Object.defineProperty(Blob.prototype,'size',{get:function(){return 17;}});
        Object.defineProperty(File.prototype,'lastModified',{get:function(){return 123456;}});
        String.prototype.normalize=function(){return 'same';};
        Number.isFinite=function(){return true;};Math.abs=function(){return 0;};
        listener({target:input,isTrusted:true});
        """)
        XCTAssertEqual(completion(context), "MISMATCH_NAME")
        XCTAssertNil(context.exception)
    }

    func testCleanupRemovesReceiptStateAndListener() throws {
        let context = try context()
        context.evaluateScript("var saved=window[stateKeys[0]];")
        XCTAssertEqual(context.evaluateScript(NativeUploadScript.cleanupJS(nonce: "integrity-fixture"))?.toString(), "OK")
        XCTAssertEqual(context.evaluateScript("Object.getOwnPropertyNames(window).filter(function(k){return beforeKeys.indexOf(k)<0;}).length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("saved.read()")?.toString(), "OWNER_CHANGED")
        XCTAssertTrue(context.evaluateScript("listener===null && Object.keys(registered).length===0")!.toBool())
    }

    func testExpiryDisposesOriginalClosureAfterGlobalReplacement() throws {
        let context = try context()
        context.evaluateScript("var saved=window[stateKeys[0]];Object.defineProperty(window,stateKeys[0],{value:{read:function(){return 'OK';}},configurable:true});fixtureTimers[0]();")
        XCTAssertEqual(context.evaluateScript("saved.read()")?.toString(), "OWNER_CHANGED")
        XCTAssertTrue(context.evaluateScript("listener===null && Object.keys(registered).length===0 && fixtureTimers[0]===null")!.toBool())
        XCTAssertNotEqual(completion(context), NativeUploadDOMFixture.receipt)
        XCTAssertNil(context.exception)
    }

}


/// Prototype adapters model the production DOM getter/method boundary. These
/// are test-only JavaScriptCore stand-ins; production has no plain-object fallback.
enum NativeUploadDOMFixture {
    static let receipt = "SB_UPLOAD_RECEIPT:8ECF0954-3FD6-44E9-8D76-B6F3FFBF7319"
    static let source = """
    var listener=null, registered={}, fixtureTimers=[];
    function EventTarget(){}
    EventTarget.prototype.addEventListener=function(t,f){registered[t]=f;listener=f;};
    EventTarget.prototype.removeEventListener=function(t,f){if(registered[t]===f)delete registered[t];listener=null;};
    function Event(){}
    Object.defineProperty(Event.prototype,'target',{get:function(){return this.target;},configurable:true});
    function Blob(){}
    Object.defineProperty(Blob.prototype,'size',{get:function(){return this._size;},set:function(v){this._size=v;},configurable:true});
    function File(value){this._name=value.name;this._size=value.size;this._lastModified=value.lastModified;}
    File.prototype=Object.create(Blob.prototype);
    Object.defineProperty(File.prototype,'name',{get:function(){return this._name;},set:function(v){this._name=v;},configurable:true});
    Object.defineProperty(File.prototype,'lastModified',{get:function(){return this._lastModified;},set:function(v){this._lastModified=v;},configurable:true});
    function FileList(values){this._entries=[];for(var i=0;i<values.length;i++)this.push(values[i]);}
    FileList.prototype.push=function(value){var f=value instanceof File ? value : new File(value);this[this._entries.length]=f;return this._entries.push(f);};
    Object.defineProperty(FileList.prototype,'length',{get:function(){return this._entries.length;},configurable:true});
    FileList.prototype.item=function(i){return this._entries[i]||null;};
    function HTMLInputElement(){}
    Object.defineProperty(HTMLInputElement.prototype,'files',{
      get:function(){return this._files;},set:function(v){this._files=v instanceof FileList?v:new FileList(v);},configurable:true});
    var document={};
    var input=Object.assign(new HTMLInputElement(),{tagName:'INPUT',type:'file',isConnected:true,ownerDocument:document,
      disabled:false,files:[],hasAttribute:function(){return false;},click:function(){}});
    document.querySelector=function(){return input;};
    var window=Object.assign(new EventTarget(),{location:{href:'https://fixture.invalid/upload'},
      setTimeout:function(fn){fixtureTimers.push(fn);return fixtureTimers.length-1;},
      clearTimeout:function(id){fixtureTimers[id]=null;}});
    """
}
