import Darwin
import Foundation

// Core-only mechanism. The approved path validates the suspended image; the
// lower native seam refuses without an explicit verifier. No CLI discovery.
enum WebFunnelProcess {
    typealias Q=WebFunnelQuery
    static let pollMilliseconds:Int32=25,terminationGrace:TimeInterval=0.25
    enum Stream {case output,error}
    enum Read {case output(Data),discarded(Int),pending,end,limit,failure}
    enum Exit {case running,exited(Int32),unknown}
    enum Signal {case terminate,kill}
    protocol Resource:AnyObject {
        var started:Bool {get}
        var setupFailed:Bool {get}
        func admit(_ permitted:()->Bool)->Bool
        func read(_ stream:Stream,remaining:Int)->Read
        func exit()->Exit
        func groupTerminal()->Bool
        func signal(_ signal:Signal)->Bool
        func close(_ stream:Stream)->Bool
        func reap()->Bool
        func pause()
    }
    struct Dependencies {
        let clock:()->TimeInterval
        let spawn:(URL,Q.Plan,@escaping()->Bool)->Resource?
    }
    static func launch(isolated:Bool,permitted:@escaping()->Bool,executable:@escaping()->URL?,dependencies:Dependencies)->Q.Launch {
        {plan,sink in
            guard !isolated,permitted(),sink.isPermitted,let path=executable(),path.isFileURL,path.host==nil || path.host=="localhost",
                  path.path.hasPrefix("/"),!path.path.utf8.contains(0),path.path.utf8.count<=4096,path.user==nil,path.password==nil,path.port==nil,path.query==nil,path.fragment==nil,
                  permitted(),sink.isPermitted else {return nil}
            let task=Task(plan,sink,{permitted() && sink.isPermitted},path,dependencies);task.start();return task
        }
    }
    typealias Verify=(pid_t,()->Bool)->Bool
    static func native(isolated:Bool,permitted:@escaping()->Bool,executable:@escaping()->URL?,verify:@escaping Verify={_,_ in false})->Q.Launch {
        launch(isolated:isolated,permitted:permitted,executable:executable,dependencies:Dependencies(clock:{ProcessInfo.processInfo.systemUptime},spawn:{POSIXResource.spawn($0,$1,$2,verify)}))
    }
    static func approvedNative(isolated:Bool,permitted:@escaping()->Bool,proof:WebFunnelExecutable.Proof)->Q.Launch {
        native(isolated:isolated,permitted:permitted,executable:{proof.url},verify:{pid,gate in
            WebFunnelExecutable.verifyRunning(pid,proof:proof,isolated:isolated,permitted:gate)
        })
    }
    private final class Task:Q.Child {
        let plan:Q.Plan,sink:Q.Sink,permitted:()->Bool,path:URL,dependencies:Dependencies
        let queue=DispatchQueue(label:"RemSound.Funnel.child",qos:.utility),lock=NSLock()
        var cancelled=false
        init(_ plan:Q.Plan,_ sink:Q.Sink,_ permitted:@escaping()->Bool,_ path:URL,_ dependencies:Dependencies) {self.plan=plan;self.sink=sink;self.permitted=permitted;self.path=path;self.dependencies=dependencies}
        func cancel(){lock.lock();cancelled=true;lock.unlock()}
        func start(){queue.async{self.run();self.queue.async{self.sink.retired()}}}
        func run(){
            let start=dependencies.clock()
            guard start.isFinite,start>=0 else {withoutChild(.io);return}
            func allowed()->Bool {lock.lock();let stopped=cancelled;lock.unlock();return !stopped && permitted()}
            guard allowed() else {withoutChild(.cancelled);return}
            guard let resource=dependencies.spawn(path,plan,allowed) else {withoutChild(allowed() ? .unavailable:.cancelled);return}
            var outputOpen=true,errorOpen=true,outputClosing=false,errorClosing=false,outCount=0,errCount=0,exitSeen=false,last=start,stopAt:TimeInterval?,term=false,killed=false
            if !resource.started {sink.failed(.unavailable);stopAt=start}
            else if resource.setupFailed {sink.failed(.io);stopAt=start}
            func fail(_ reason:Q.Failure){sink.failed(reason);if stopAt==nil {stopAt=last}}
            func close(_ stream:Stream){
                if stream == .output {outputClosing=true} else {errorClosing=true}
                guard resource.close(stream) else {fail(.io);return}
                if stream == .output {outputOpen=false;sink.stdoutClosed()} else {errorOpen=false;sink.stderrClosed()}
            }
            if resource.started,!resource.setupFailed {
                // The child remains suspended throughout inspection. A slow raw
                // Security call retains ownership; its return is not a timeout receipt.
                var admissionFailure:Q.Failure?
                let admitted=resource.admit {
                    guard admissionFailure==nil else {return false}
                    guard allowed() else {admissionFailure = .cancelled;return false}
                    let now=dependencies.clock()
                    guard now.isFinite,now>=last else {admissionFailure = .io;return false}
                    last=now
                    guard now-start<plan.timeout else {admissionFailure = .timedOut;return false}
                    return true
                }
                if let reason=admissionFailure {fail(reason)}
                let now=dependencies.clock()
                if !now.isFinite || now<last {fail(.io)} else {last=now}
                if !allowed() {fail(.cancelled)}
                else if now.isFinite,now-start>=plan.timeout {fail(.timedOut)}
                else if !admitted {fail(.unavailable)}
            }
            while true {
                let clock=dependencies.clock(),broken = !clock.isFinite || clock<last
                if broken {fail(.io)} else {last=clock}
                lock.lock();let cancel=cancelled;lock.unlock()
                if cancel || !permitted() {fail(.cancelled)}
                if !broken,last-start>=plan.timeout {fail(.timedOut)}
                for stream in [Stream.output,.error] {
                    guard stream == .output ? outputOpen:errorOpen else {continue}
                    if stream == .output ? outputClosing:errorClosing {close(stream);continue}
                    let remaining=stream == .output ? plan.stdoutLimit-outCount:plan.stderrLimit-errCount
                    switch resource.read(stream,remaining:remaining) {
                    case .pending:break
                    case .end:close(stream)
                    case .failure:fail(.io);close(stream)
                    case .limit:fail(.outputLimit);close(stream)
                    case .output(let data):
                        guard data.count<=plan.chunkLimit,data.count<=remaining else {fail(.outputLimit);close(stream);continue}
                        if stream == .output {outCount += data.count} else {errCount += data.count}
                        if stopAt==nil {if stream == .output {sink.stdout(data)} else {sink.stderr(data)}}
                    case .discarded(let count):
                        guard stream == .error,count>=0,count<=plan.chunkLimit,count<=remaining else {fail(.outputLimit);close(stream);continue}
                        errCount += count
                    }
                }
                switch resource.exit() {
                case .running:break
                case .unknown:fail(.io)
                case .exited(let status):if !exitSeen {exitSeen=true;sink.exited(status);if status != 0 {fail(.commandFailed)}}
                }
                let terminal=exitSeen && resource.groupTerminal()
                if exitSeen && !terminal {fail(.io)}
                if stopAt != nil,!term {term=true;if !resource.signal(.terminate){fail(.io)}}
                if let stopping=stopAt,!killed,(broken || last-stopping>=terminationGrace) {killed=true;if !resource.signal(.kill){fail(.io)}}
                if terminal,!outputOpen,!errorOpen,resource.reap() {return}
                resource.pause()
            }
        }
        private func withoutChild(_ reason:Q.Failure){sink.failed(reason);sink.stdoutClosed();sink.stderrClosed();sink.exited(-1)}
    }
    // A waitable leader reserves the group identity until all owned pipe IO
    // and observed group members are terminal. Reaping is the last OS action;
    // no signal is sent to a reusable PID/group after that point.
    private final class SetupResource:Resource {
        let setup:WebFunnelSetup
        init(_ setup:WebFunnelSetup){self.setup=setup}
        var started:Bool {false}
        func admit(_ permitted:()->Bool)->Bool {false}
        func read(_ stream:Stream,remaining:Int)->Read {.end}
        func exit()->Exit {.exited(-1)}
        func groupTerminal()->Bool {setup.complete}
        func signal(_ signal:Signal)->Bool {true}
        func close(_ stream:Stream)->Bool {setup.retire()}
        func reap()->Bool {setup.complete}
        func pause(){Thread.sleep(forTimeInterval:Double(pollMilliseconds)/1000)}
    }
    private final class POSIXResource:Resource {
        static let maximumGroupMembers=64,zombieStatus:UInt32=5,stoppedStatus:UInt32=4
        private static let actionsIdentity = -1,attributesIdentity = -2,unresolvedIdentity = -3
        let pid:pid_t
        var output:Int32,error:Int32,reaped=false,outputCloseUncertain=false,errorCloseUncertain=false
        let parentWritersClosed:Bool,setup:WebFunnelSetup
        let verify:Verify
        var admissionAttempted=false
        var setupFailed:Bool {!parentWritersClosed}
        func admit(_ permitted:()->Bool)->Bool {
            guard !admissionAttempted else {return false};admissionAttempted=true
            guard parentWritersClosed,permitted(),suspendedLeader(),verify(pid,permitted),
                  permitted(),suspendedLeader(),permitted() else {return false}
            return Darwin.kill(pid,SIGCONT)==0
        }
        private func suspendedLeader()->Bool {
            guard !reaped else {return false}
            var info=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size else {return false}
            return info.pbi_pid==UInt32(pid) && info.pbi_ppid==UInt32(getpid()) && info.pbi_pgid==UInt32(pid) && info.pbi_status==Self.stoppedStatus
        }
        var buffer=[UInt8](repeating:0,count:Q.maximumChunkBytes)
        init(_ pid:pid_t,_ output:Int32,_ error:Int32,_ setup:WebFunnelSetup,_ verify:@escaping Verify){self.pid=pid;self.output=output;self.error=error;self.setup=setup;self.verify=verify;self.parentWritersClosed=setup.retire(except:[Int(output),Int(error)])}
        static func spawn(_ path:URL,_ plan:Q.Plan,_ permitted:@escaping()->Bool,_ verify:@escaping Verify)->Resource? {
            guard permitted() else {return nil}
            let setup=WebFunnelSetup()
            var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
            func refused()->Resource? {
                // Nil promises no outstanding raw ownership, including a failed
                // pre-spawn transaction. Ambiguous cleanup retains this Task.
                setup.retire() ? nil:SetupResource(setup)
            }
            func pipePair()->(Int32,Int32)? {
                guard permitted(),setup.remaining>=4 else {return nil}
                var pair=[Int32](repeating:-1,count:2)
                guard Darwin.pipe(&pair)==0 else {return nil}
                for fd in pair {_ = setup.own(Int(fd)){Darwin.close(fd)==0}}
                for index in 0..<2 {
                    let original=pair[index]
                    if original<3 {
                        let copy=fcntl(original,F_DUPFD_CLOEXEC,3)
                        guard copy>=3 else {return nil}
                        _ = setup.own(Int(copy)){Darwin.close(copy)==0}
                        guard setup.close(Int(original)) else {return nil};pair[index]=copy
                    }
                    guard fcntl(pair[index],F_SETFD,FD_CLOEXEC)==0 else {return nil}
                }
                return(pair[0],pair[1])
            }
            guard let out=pipePair(),let err=pipePair(),permitted(),setup.remaining>=2,
                  posix_spawn_file_actions_init(&actions)==0 else {return refused()}
            guard actions != nil else {_ = setup.own(Self.unresolvedIdentity){false};return refused()}
            // addopen/addclose may relocate the opaque object. The ledger must
            // retire the current inout handle, not the pointer returned by init.
            _ = setup.own(Self.actionsIdentity){posix_spawn_file_actions_destroy(&actions)==0}
            guard permitted(),posix_spawnattr_init(&attributes)==0 else {return refused()}
            guard attributes != nil else {_ = setup.own(Self.unresolvedIdentity){false};return refused()}
            _ = setup.own(Self.attributesIdentity){posix_spawnattr_destroy(&attributes)==0}
            let descriptors=[out.0,out.1,err.0,err.1]
            for fd in [out.0,err.0] {let flags=fcntl(fd,F_GETFL);guard flags>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else {return refused()}}
            guard posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)==0,
                  posix_spawn_file_actions_adddup2(&actions,out.1,STDOUT_FILENO)==0,
                  posix_spawn_file_actions_adddup2(&actions,err.1,STDERR_FILENO)==0 else {return refused()}
            for fd in descriptors {guard posix_spawn_file_actions_addclose(&actions,fd)==0 else {return refused()}}
            var empty=sigset_t(),defaults=sigset_t();sigemptyset(&empty);sigemptyset(&defaults)
            for signal in [SIGTERM,SIGINT,SIGPIPE] {sigaddset(&defaults,signal)}
            let flags=Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_START_SUSPENDED)
            guard posix_spawnattr_setpgroup(&attributes,0)==0,posix_spawnattr_setsigmask(&attributes,&empty)==0,
                  posix_spawnattr_setsigdefault(&attributes,&defaults)==0,posix_spawnattr_setflags(&attributes,flags)==0,permitted() else {return refused()}
            let arguments=[path.path]+plan.arguments,environment=["TAILSCALE_BE_CLI=1","LC_ALL=C"]
            var argv=arguments.map{strdup($0)}+[nil],env=environment.map{strdup($0)}+[nil]
            defer {for pointer in argv+env {free(pointer)}}
            guard argv.dropLast().allSatisfy({$0 != nil}),env.dropLast().allSatisfy({$0 != nil}),permitted() else {return refused()}
            var pid:pid_t=0
            let code=path.path.withCString{posix_spawn(&pid,$0,&actions,&attributes,&argv,&env)}
            guard code==0 else {return refused()}
            guard pid>0 else {_ = setup.own(Self.unresolvedIdentity){false};return refused()}
            return POSIXResource(pid,out.0,err.0,setup,verify)
        }
        func read(_ stream:Stream,remaining:Int)->Read {
            let fd=stream == .output ? output:error
            if stream == .output ? outputCloseUncertain:errorCloseUncertain {return .pending}
            guard fd>=0,remaining>=0 else {return .failure}
            let maximum=min(buffer.count,remaining+1)
            let count=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,maximum)}
            if count==0 {return .end}
            if count<0 {return errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR ? .pending:.failure}
            guard count<=remaining else {return .limit}
            return .output(Data(buffer.prefix(count)))
        }
        func exit()->Exit {
            guard !reaped else {return .unknown};var info=siginfo_t()
            guard waitid(P_PID,id_t(pid),&info,WEXITED|WNOHANG|WNOWAIT)==0 else {return errno==EINTR ? .running:.unknown}
            guard info.si_pid==pid else {return .running}
            return .exited(info.si_code==CLD_EXITED ? info.si_status:128+info.si_status)
        }
        func groupTerminal()->Bool {
            guard !reaped,parentWritersClosed else {return false}
            var ids=[pid_t](repeating:0,count:Self.maximumGroupMembers+1)
            let count=ids.withUnsafeMutableBytes{proc_listpgrppids(pid,$0.baseAddress,Int32($0.count))}
            guard count>0,count<=Self.maximumGroupMembers,ids.prefix(Int(count)).contains(pid) else {return false}
            for member in ids.prefix(Int(count)) where member>0 && member != pid {
                var info=proc_bsdinfo();let size=Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(member,PROC_PIDTBSDINFO,0,&info,size)==size else {return false}
                if info.pbi_pgid==UInt32(pid),info.pbi_status != Self.zombieStatus {return false}
            }
            return true
        }
        func signal(_ signal:Signal)->Bool {guard !reaped else {return false};return Darwin.kill(-pid,signal == .kill ? SIGKILL:SIGTERM)==0}
        func close(_ stream:Stream)->Bool {
            let fd=stream == .output ? output:error;guard fd>=0 else {return true}
            // An interrupted close can leave descriptor ownership uncertain.
            // Never retry a raw number which another thread could have reused.
            if stream == .output ? outputCloseUncertain:errorCloseUncertain {return false}
            guard setup.close(Int(fd)) else {if stream == .output {outputCloseUncertain=true} else {errorCloseUncertain=true};return false}
            if stream == .output {output = -1} else {error = -1};return true
        }
        func reap()->Bool {guard !reaped else {return true};guard setup.complete else {return false};var status:Int32=0;guard waitpid(pid,&status,WNOHANG)==pid else {return false};reaped=true;return true}
        func pause(){var descriptors=[pollfd(fd:outputCloseUncertain ? -1:output,events:Int16(POLLIN|POLLHUP),revents:0),pollfd(fd:errorCloseUncertain ? -1:error,events:Int16(POLLIN|POLLHUP),revents:0)];_ = Darwin.poll(&descriptors,nfds_t(descriptors.count),pollMilliseconds);if output<0 && error<0 {Thread.sleep(forTimeInterval:Double(pollMilliseconds)/1000)}}
    }
}

extension WebFunnelProcess.Resource {
    var started:Bool {true}
    var setupFailed:Bool {false}
}
