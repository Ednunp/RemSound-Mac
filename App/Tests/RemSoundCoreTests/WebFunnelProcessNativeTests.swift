import Darwin
import XCTest
@testable import RemSoundCore

final class WebFunnelProcessNativeTests:XCTestCase {
    typealias P=WebFunnelProcess;typealias Q=WebFunnelQuery
    final class Visit {
        let verify:P.Verify
        let queue=DispatchQueue(label:"test.Funnel.native")
        let path:URL,done=XCTestExpectation(description:"native query retired")
        var results=[Q.Result]()
        lazy var service=Q.Service(queue:queue,isolated:false,enabled:true,current:{_ in true},launch:P.native(isolated:false,permitted:{true},executable:{[path] in path},verify:verify))
        init(_ path:URL,verify:@escaping P.Verify={_,gate in gate()})throws{
            self.verify=verify;self.path=path
            for suffix in ["pid","child","status","node","serve","funnel"] {
                let file=URL(fileURLWithPath:path.path+"."+suffix)
                if FileManager.default.fileExists(atPath:file.path) {
                    let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {throw CocoaError(.fileReadUnsupportedScheme)}
                    try FileManager.default.removeItem(at:file)
                }
            }
        }
        func start(){XCTAssertTrue(service.request(.init(identity:UUID(),localPort:6001)){[self] in results.append($0);done.fulfill()})}
        func wait(_ timeout:Double=4,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(XCTWaiter().wait(for:[done],timeout:timeout),.completed,file:file,line:line)}
        func close(){let stopped=XCTestExpectation(description:"full shutdown");XCTAssertTrue(service.shutdown{stopped.fulfill()});XCTAssertEqual(XCTWaiter().wait(for:[stopped],timeout:2),.completed)}
    }
    func visit(_ name:String)throws->Visit {
        let env=ProcessInfo.processInfo.environment
        guard let root=env["REMSOUND_TEST_ROOT"],let fixtures=env["REMSOUND_TEST_FUNNEL_FIXTURES"] else {throw XCTSkip("Explicit owned process fixtures are required")}
        let path=URL(fileURLWithPath:fixtures).appendingPathComponent(name).standardizedFileURL
        guard path.path.hasPrefix(URL(fileURLWithPath:root).standardizedFileURL.path+"/"),path.resolvingSymlinksInPath()==path,
              FileManager.default.isExecutableFile(atPath:path.path) else {throw CocoaError(.fileReadUnsupportedScheme)}
        return try Visit(path)
    }
    func pid(_ visit:Visit,_ suffix:String="pid")->pid_t? {
        let path=visit.path.path+"."+suffix,deadline=Date().addingTimeInterval(2)
        while Date()<deadline {if let text=try? String(contentsOfFile:path,encoding:.utf8),let pid=Int32(text),pid>0 {return pid};Thread.sleep(forTimeInterval:0.005)}
        XCTFail("Owned fixture did not start");return nil
    }
    func assertReaped(_ pid:pid_t,file:StaticString=#filePath,line:UInt=#line){var status:Int32=0;XCTAssertEqual(waitpid(pid,&status,WNOHANG),-1,file:file,line:line);XCTAssertEqual(errno,ECHILD,file:file,line:line)}
    func testActualTwoQueriesAndCLIEnvironment()throws{let v=try visit("normal");v.start();v.wait();guard case .mapping(let address,true)?=v.results.first else {v.close();return XCTFail("no mapped result")};XCTAssertEqual(address.url.absoluteString,"https://mac.tail.ts.net");if let id=pid(v){assertReaped(id)};v.close()}
    func testActualNonzeroIsValueFree()throws{let v=try visit("nonzero");v.start();v.wait();XCTAssertEqual(v.results,[.failed(.commandFailed)]);if let id=pid(v){assertReaped(id)};v.close()}
    func testActualStdoutBound()throws{let v=try visit("stdout");v.start();v.wait();XCTAssertEqual(v.results,[.failed(.outputLimit)]);if let id=pid(v){assertReaped(id)};v.close()}
    func testActualStderrBound()throws{let v=try visit("stderr");v.start();v.wait();XCTAssertEqual(v.results,[.failed(.outputLimit)]);if let id=pid(v){assertReaped(id)};v.close()}
    func testActualHalfcloseStillWaitsChild()throws{let v=try visit("halfclosed");v.start();v.wait();XCTAssertEqual(v.results,[.unknown]);if let id=pid(v){assertReaped(id)};v.close()}
    func testActualSilentCancellationEscalatesAndReaps()throws{let v=try visit("silent");v.start();guard let id=pid(v) else {v.wait();v.close();return};v.service.cancel();v.wait();XCTAssertEqual(v.results,[.failed(.cancelled)]);assertReaped(id);v.close()}
    func testActualDeadlineEscalatesAndReaps()throws{let v=try visit("deadline");v.start();v.wait(14);XCTAssertEqual(v.results,[.failed(.timedOut)]);if let id=pid(v){assertReaped(id)};v.close()}
    func testActualInheritedPipeHolderRetiresBeforeReplacement()throws{let v=try visit("inherited");v.start();guard let leader=pid(v),let child=pid(v,"child") else {v.wait();v.close();return};v.wait(7);XCTAssertEqual(v.results,[.failed(.io)]);assertReaped(leader);var info=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size),read=proc_pidinfo(child,PROC_PIDTBSDINFO,0,&info,size);XCTAssertTrue(read==0 || info.pbi_status==5);v.close()}
    func testActualSpawnFailureChurnClosesPipes()throws{
        let normal=try visit("normal"),missing=normal.path.appendingPathExtension("absent")
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        func one()throws{let v=try Visit(missing);v.start();v.wait();XCTAssertEqual(v.results,[.failed(.unavailable)]);v.close()}
        func descriptors()->Int{(0..<4096).reduce(0){$0+(fcntl(Int32($1),F_GETFD)>=0 ? 1:0)}}
        try one();let before=descriptors();for _ in 0..<16 {try one()};XCTAssertLessThanOrEqual(descriptors(),before+1)
    }




    func testActualFixedBGCommandAndBothPrintedApprovalPages() throws {
        let v=try visit("approval-needed");var pages=[URL]()
        XCTAssertTrue(v.service.turnOn(.init(identity:UUID(),localPort:6001),openPage:{url,done in pages.append(url);done();return true}){[v] in v.results.append($0);v.done.fulfill()})
        v.wait();XCTAssertEqual(v.results,[.turnedOn]);XCTAssertEqual(pages.map(\.path),["/f/serve","/f/funnel"])
        if let id=pid(v) {assertReaped(id)};v.close()
    }
    func testActualBGCommandCancelRetiresWaitingChild() throws {
        let v=try visit("silent")
        XCTAssertTrue(v.service.turnOn(.init(identity:UUID(),localPort:6001),openPage:{_,done in done();return true}){[v] in v.results.append($0);v.done.fulfill()})
        guard let id=pid(v) else {v.wait();v.close();return};v.service.cancel();v.wait();XCTAssertEqual(v.results,[.failed(.cancelled)]);assertReaped(id);v.close()
    }
}
