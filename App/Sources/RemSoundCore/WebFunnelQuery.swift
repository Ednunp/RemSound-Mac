import Foundation

// This owner has no executable resolver or native driver. Its launch contract
// requires independent exit, both pipe closures and callback-retirement receipts.
enum WebFunnelQuery {
    static let maximumErrorBytes=8192,maximumChunkBytes=16_384,maximumWaiters=16
    static let timeout:TimeInterval=10
    struct Scope:Equatable,Sendable {
        let identity:UUID
        let localPort:UInt16
    }
    enum Failure:Equatable,Sendable {case notInstalled,unavailable,cancelled,timedOut,outputLimit,io,commandFailed}
    enum Result:Equatable,Sendable {
        case turnedOn
        case enablePreflight(WebFunnelStatus.EnablePreflight)
        case unknown,noMatchingRoot,notReady
        case mapping(WebFunnelStatus.Address,allowed:Bool)
        case failed(Failure)
    }
    protocol Child:AnyObject {func cancel()}
    struct Plan:Equatable,Sendable {
        let query:WebFunnelStatus.Query
        var arguments:[String] {query.arguments}
        var timeout:TimeInterval {if case .turnOn=query {return 600};return WebFunnelQuery.timeout}
        var stdoutLimit:Int {WebFunnelStatus.maximumOutputBytes}
        var stderrLimit:Int {maximumErrorBytes}
        var chunkLimit:Int {maximumChunkBytes}
    }
    // A nil return promises that no child or callback work was created. A
    // returned child owns its deadline and must retire even after cancellation.
    typealias Launch=(Plan,Sink)->Child?
    final class Sink {
        private let lock=NSLock(),failure:FailureBox,wake:()->Void,permission:()->Bool
        private let scanPages:Bool
        private var outputLine=Data(),errorLine=Data(),outputLong=false,errorLong=false,pages=[URL](),seen=Set<URL>()
        private var bytes=Data(),errorCount=0,outClosed=false,errClosed=false,exit:Int32?,retirement=false,closed=false,queued=false
        fileprivate init(scanPages:Bool=false,failure:FailureBox,permission:@escaping()->Bool,wake:@escaping()->Void) {self.scanPages=scanPages;self.failure=failure;self.permission=permission;self.wake=wake}
        // The native driver must recheck this before each sensitive factory and
        // launch. Scope observation alone never supplies process permission.
        var isPermitted:Bool {
            lock.lock();let live = !closed && !retirement;lock.unlock();guard live,permission() else {return false}
            lock.lock();defer{lock.unlock()};return !closed && !retirement
        }
        func stdout(_ data:Data) {append(data,error:false)}
        func stderr(_ data:Data) {append(data,error:true)}
        private func append(_ data:Data,error:Bool) {
            lock.lock()
            guard !closed else {lock.unlock();return}
            if (error ? errClosed:outClosed) {failure.set(.io)}
            else if data.count>maximumChunkBytes || data.count>(error ? maximumErrorBytes-errorCount:WebFunnelStatus.maximumOutputBytes-bytes.count) {failure.set(.outputLimit)}
            else if failure.value==nil {
                if error {errorCount += data.count} else {bytes.append(data)}
                if scanPages {scan(data,error:error)}
            }
            signalLocked()
        }
        private func scan(_ data:Data,error:Bool) {
            var line=error ? errorLine:outputLine,long=error ? errorLong:outputLong
            for byte in data {
                if byte==10 {if !long {accept(line)};line.removeAll(keepingCapacity:true);long=false}
                else if !long {if line.count<4096 {line.append(byte)} else {line.removeAll(keepingCapacity:true);long=true}}
            }
            if error {errorLine=line;errorLong=long} else {outputLine=line;outputLong=long}
        }
        private func accept(_ line:Data) {
            guard let text=String(data:line,encoding:.utf8),let start=text.range(of:"https://login.tailscale.com/"),
                  let url=WebFunnelStatus.approvalURL(String(text[start.lowerBound...]).trimmingCharacters(in:.whitespacesAndNewlines)),!seen.contains(url) else {return}
            guard seen.count<2 else {failure.set(.outputLimit);return}
            seen.insert(url);pages.append(url)
        }
        func stdoutClosed() {update{if scanPages,!outputLong {accept(outputLine)};outputLine=Data();outClosed=true}}
        func stderrClosed() {update{if scanPages,!errorLong {accept(errorLine)};errorLine=Data();errClosed=true}}
        fileprivate func takePages()->[URL] {lock.lock();defer{lock.unlock()};let next=pages;pages.removeAll();return next}
        func exited(_ status:Int32) {update{if exit==nil {exit=status;if status != 0 {failure.set(.commandFailed)}}}}
        func failed(_ reason:Failure) {update{failure.set(reason)}}
        func retired() {update{retirement=true}}
        private func update(_ body:()->Void) {lock.lock();guard !closed else {lock.unlock();return};body();signalLocked()}
        private func signalLocked() {let signal = !queued;queued=true;lock.unlock();if signal {wake()}}
        fileprivate func inspect()->(complete:Bool,status:Int32?) {lock.lock();defer{lock.unlock()};queued=false;return(outClosed && errClosed && exit != nil && retirement,exit)}
        fileprivate func take()->Data {lock.lock();defer{lock.unlock()};closed=true;let data=bytes;bytes=Data();return data}
    }
    fileprivate final class FailureBox {
        private let lock=NSLock();private var first:Failure?
        var value:Failure? {lock.lock();defer{lock.unlock()};return first}
        func set(_ reason:Failure) {lock.lock();if first==nil {first=reason};lock.unlock()}
    }
    private enum Purpose:Equatable {case address,enablePreflight,turnOn}
    private final class Job {
        let scope:Scope,purpose:Purpose,completion:(Result)->Void,failure=FailureBox()
        let openPage:((URL,@escaping()->Void)->Bool)?
        var pagePending=0,configuration=Data()
        var query=WebFunnelStatus.Query.funnel,funnel=WebFunnelStatus.Funnel.unknown
        var child:Child?,sink:Sink?,cancelSent=false,delivering=false
        init(_ scope:Scope,_ purpose:Purpose,_ completion:@escaping(Result)->Void,openPage:((URL,@escaping()->Void)->Bool)?) {self.scope=scope;self.purpose=purpose;self.completion=completion;self.openPage=openPage;if purpose == .turnOn {query = .turnOn(scope.localPort)}}
    }
    final class Service {
        private let owner:Owner
        init(queue:DispatchQueue,isolated:Bool,enabled:Bool=false,current:@escaping(Scope)->Bool,launch:@escaping Launch) {owner=Owner(queue,isolated,enabled,current,launch)}
        deinit {owner.shutdown(nil)}
        @discardableResult func request(_ scope:Scope,completion:@escaping(Result)->Void)->Bool {
            owner.request(scope,completion)
        }
        @discardableResult func prepareEnable(_ scope:Scope,completion:@escaping(Result)->Void)->Bool {owner.request(scope,completion,purpose:.enablePreflight)}
        @discardableResult func turnOn(_ scope:Scope,openPage:@escaping(URL,@escaping()->Void)->Bool,completion:@escaping(Result)->Void)->Bool {owner.request(scope,completion,purpose:.turnOn,openPage:openPage)}
        func cancel() {owner.cancel()}
        func cancel(_ scope:Scope) {owner.cancel(scope)}
        func setEnabled(_ value:Bool) {owner.setEnabled(value)}
        @discardableResult func shutdown(_ completion:@escaping()->Void)->Bool {owner.shutdown(completion)}
    }
    private final class PageReceipt {
        private let lock=NSLock();private var taken=false
        func claim()->Bool {lock.lock();defer{lock.unlock()};guard !taken else {return false};taken=true;return true}
    }
    private final class Owner {
        private let queue:DispatchQueue,isolated:Bool,current:(Scope)->Bool,launch:Launch,lock=NSLock()
        private var enabled:Bool,permanent=false,job:Job?,waiters=[()->Void](),retained:Owner?,queued=false
        init(_ queue:DispatchQueue,_ isolated:Bool,_ enabled:Bool,_ current:@escaping(Scope)->Bool,_ launch:@escaping Launch) {self.queue=queue;self.isolated=isolated;self.enabled=enabled;self.current=current;self.launch=launch}
        func request(_ scope:Scope,_ completion:@escaping(Result)->Void,purpose:Purpose = .address,openPage:((URL,@escaping()->Void)->Bool)? = nil)->Bool {
            lock.lock();guard !isolated,enabled,!permanent,job==nil,scope.localPort>0 else {lock.unlock();return false}
            let next=Job(scope,purpose,completion,openPage:openPage);job=next;retained=self;signalLocked();lock.unlock();return true
        }
        private func permitted(_ candidate:Job)->Bool {lock.lock();defer{lock.unlock()};return !isolated && enabled && !permanent && job === candidate && candidate.failure.value==nil}
        func setEnabled(_ value:Bool) {lock.lock();enabled=value;if !value {job?.failure.set(.cancelled)};if job != nil {signalLocked()};lock.unlock()}
        func cancel(_ scope:Scope? = nil) {lock.lock();guard scope==nil || job?.scope==scope else {lock.unlock();return};job?.failure.set(.cancelled);if job != nil {signalLocked()};lock.unlock()}
        @discardableResult func shutdown(_ completion:(()->Void)?)->Bool {
            lock.lock();guard completion==nil || waiters.count<maximumWaiters else {lock.unlock();return false}
            permanent=true;enabled=false;job?.failure.set(.cancelled);if let completion {waiters.append(completion)};retained=self;signalLocked();lock.unlock();return true
        }
        private func signal() {lock.lock();signalLocked();lock.unlock()}
        private func signalLocked() {
            guard !queued else {return};queued=true
            queue.async{self.lock.lock();self.queued=false;let active=self.job;self.lock.unlock();if let active {self.pump(active)} else {self.drain()}}
        }
        private func valid(_ active:Job)->Bool {
            guard permitted(active) else {return false}
            let observed=current(active.scope)
            return observed && permitted(active)
        }
        private func pump(_ active:Job) {
            lock.lock();let owns=job === active;lock.unlock();guard owns,!active.delivering else {return}
            if active.sink==nil {
                guard valid(active) else {active.failure.set(.cancelled);deliver(active,.unknown);return}
                let sink=Sink(scanPages:active.purpose == .turnOn,failure:active.failure,permission:{[weak self,weak active] in guard let self,let active else {return false};return self.permitted(active)},wake:{[weak self] in self?.signal()})
                active.sink=sink
                // Emissions may be synchronous; their coalesced wake runs only
                // after this factory returns and the real child is installed.
                active.child=launch(Plan(query:active.query),sink)
                if active.child==nil {active.failure.set(.unavailable);_ = sink.take();active.sink=nil;deliver(active,.unknown);return}
            }
            if active.failure.value != nil,!active.cancelSent {active.cancelSent=true;active.child?.cancel()}
            guard let sink=active.sink else {return};let state=sink.inspect()
            // A writer can set the first failure between the earlier check and
            // inspect's coalesced-wake reset. Consume that edge in this turn.
            if active.failure.value != nil,!active.cancelSent {active.cancelSent=true;active.child?.cancel()}
            for url in sink.takePages() where active.failure.value==nil {
                guard valid(active),let open=active.openPage else {active.failure.set(.cancelled);break}
                active.pagePending += 1
                let receipt=PageReceipt()
                let admitted=open(url) { [self] in
                    guard receipt.claim() else {return}
                    queue.async {active.pagePending -= 1;self.pump(active)}
                }
                if !admitted,receipt.claim() {active.pagePending -= 1}
            }
            guard state.complete,active.pagePending==0 else {return}
            let bytes=sink.take();active.sink=nil;active.child=nil;active.cancelSent=false
            guard active.failure.value==nil else {deliver(active,.unknown);return}
            guard valid(active) else {active.failure.set(.cancelled);deliver(active,.unknown);return}
            guard state.status==0 else {active.failure.set(.commandFailed);deliver(active,.unknown);return}
            if active.purpose == .turnOn {deliver(active,.turnedOn);return}
            if active.query == .funnel {
                if active.purpose != .address {active.configuration=bytes}
                else {
                    active.funnel=WebFunnelStatus.funnel(bytes,exitStatus:0,localPort:active.scope.localPort)
                    guard active.funnel != .unknown else {deliver(active,.unknown);return}
                }
                active.query = .node;pump(active);return
            }
            let result:Result
            switch WebFunnelStatus.node(bytes,exitStatus:0) {
            case .notReady:result = .notReady
            case .unknown:result = .unknown
            case .running(let dns):
                if active.purpose != .address {
                    let observation=dns.map{WebFunnelStatus.prepareEnable(active.configuration,exitStatus:0,localPort:active.scope.localPort,node:$0,source:active.scope.identity)} ?? .unknown
                    deliver(active,.enablePreflight(observation));return
                }
                switch active.funnel {
                case .unknown:result = .unknown
                case .noMatchingRoot:result = dns.flatMap{WebFunnelStatus.Address.potential($0)}.map{.mapping($0,allowed:false)} ?? .noMatchingRoot
                case .mapping(let address,let allowed):
                    result = dns != nil && address.url.host==dns ? .mapping(address,allowed:allowed):.unknown
                }
            }
            deliver(active,result)
        }
        private func deliver(_ active:Job,_ proposed:Result) {
            guard !active.delivering else {return};active.delivering=true
            queue.async {
                // Keep the sole admission credit through the foreign callback's
                // raw return, including reentrant request or shutdown attempts.
                if active.failure.value==nil,!self.valid(active) {active.failure.set(.cancelled)}
                let result=active.failure.value.map{Result.failed($0)} ?? proposed
                active.completion(result)
                self.lock.lock();if self.job === active {self.job=nil};self.lock.unlock();self.drain()
            }
        }
        private func drain() {
            lock.lock();guard job==nil else {lock.unlock();return};let callbacks=waiters;waiters.removeAll();lock.unlock()
            for callback in callbacks {callback()}
            lock.lock();if job==nil && waiters.isEmpty {retained=nil};lock.unlock()
        }
    }
}
