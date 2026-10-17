#include "PluginSendEndpoint.h"
#include <condition_variable>
#include <future>
#include <iostream>
#include <cstdlib>
#include <new>

using namespace remsound;
static thread_local bool counting=false;
static thread_local size_t allocations=0,deallocations=0;
void *operator new(std::size_t n){if(counting)++allocations;if(auto *p=std::malloc(n?n:1))return p;throw std::bad_alloc();}
void *operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void *p) noexcept{if(counting&&p)++deallocations;std::free(p);}
void operator delete[](void *p) noexcept{::operator delete(p);}

static int cases=0,assertions=0,failures=0;
static void check(bool result,const char *message) {++assertions;if(!result){++failures;std::cerr<<"FAIL "<<message<<'\n';}}
template<class F> static void run(const char *name,F work){++cases;work();std::cout<<"CASE "<<name<<'\n';}
struct Sink {
    float left=0,right=0;size_t frames=0,calls=0;bool accept=true;
    PluginSendEndpoint *reenter=nullptr;bool closed=true;
    std::mutex gate;std::condition_variable changed;bool hold=false,entered=false,released=false;
    static bool write(void *context,const float *l,const float *r,size_t n,float gain) noexcept {
        auto &self=*static_cast<Sink*>(context);++self.calls;self.frames=n;self.left=l[0]*gain;self.right=r[0]*gain;
        if(self.reenter) self.closed=self.reenter->close();
        if(self.hold){std::unique_lock<std::mutex> lock(self.gate);self.entered=true;self.changed.notify_all();self.changed.wait_for(lock,std::chrono::seconds(2),[&]{return self.released;});}
        return self.accept;
    }
    PluginSendBus::Sink sink(){return {this,write};}
    void wait(){std::unique_lock<std::mutex> lock(gate);check(changed.wait_for(lock,std::chrono::seconds(2),[&]{return entered;}),"owned work entered");}
    void release(){ {std::lock_guard<std::mutex> lock(gate);released=true;}changed.notify_all();}
};
int main(){
 const float left[]={0.25f},right[]={-0.25f};
 run("closed refuses before callbacks",[&]{PluginSendEndpoint source;check(!source.ready()&&!source.process(true,left,right,1).admitted,"default closed");check(source.close(),"empty close");});
 run("default independent owner preserves ordinary sample",[&]{PluginSendEndpoint source;Sink sink;check(source.open(48000,sink.sink()),"open");check(source.process(true,left,right,1,2).stored==1,"memory stored");check(sink.left==0.5f&&sink.right==-0.5f,"gain/shape");check(source.close()&&!source.ready(),"exact close");});
 run("explicit verified owner sums without extra producer streams",[&]{auto bus=std::make_shared<PluginSendBus>();PluginSendEndpoint a,b;Sink one,two;check(a.open(48000,one.sink(),bus)&&b.open(48000,two.sink(),bus),"two registrations");a.process(false);b.process(false);a.process(true,left,right,1);b.process(true,left,right,1);a.process(true,left,right,1);check(one.calls==2&&two.calls==0&&one.left==0.5f,"one leader aligned round");check(a.close()&&b.close(),"both retired");});
 run("independent clocks do not share by rate alone",[&]{PluginSendEndpoint a,b;Sink one,two;check(a.open(48000,one.sink())&&b.open(48000,two.sink()),"independent registrations");a.process(true,left,right,1);b.process(true,left,right,1);check(one.calls==1&&two.calls==1,"two explicit independent owners");});
 run("stop prevents replay on replacement",[&]{PluginSendEndpoint source;Sink first,next;check(source.open(48000,first.sink()),"first");source.process(true,left,right,1);check(source.close(),"first terminal");check(!source.process(true,left,right,1).admitted,"stopped rejects");check(source.open(44100,next.sink()),"new native rate");source.process(true,left,right,1);check(first.calls==1&&next.calls==1,"no replay");});
 run("close waits callback lease and sink copy",[&]{PluginSendEndpoint source;Sink sink;sink.hold=true;check(source.open(48000,sink.sink()),"open");std::thread worker([&]{source.process(true,left,right,1);});sink.wait();auto closed=std::async(std::launch::async,[&]{return source.close();});check(closed.wait_for(std::chrono::milliseconds(5))==std::future_status::timeout,"close not fabricated");sink.release();worker.join();check(closed.get()&&!source.ready(),"terminal receipt");});
 run("same callback close revokes but cannot claim retirement",[&]{PluginSendEndpoint source;Sink sink;sink.reenter=&source;check(source.open(48000,sink.sink()),"open");source.process(true,left,right,1);check(!sink.closed&&!source.ready(),"self close unresolved");check(source.close(),"control later retires");});
 run("old entry paused before lease cannot enter new epoch",[&]{PluginSendEndpoint source;Sink first,next;check(source.open(48000,first.sink()),"open");Sink latch;latch.hold=true;source.testContext=&latch;source.testAfterEpoch=[](void *p){auto &state=*static_cast<Sink*>(p);std::unique_lock<std::mutex> lock(state.gate);state.entered=true;state.changed.notify_all();state.changed.wait_for(lock,std::chrono::seconds(2),[&]{return state.released;});};PluginSendBus::Receipt receipt;std::thread worker([&]{receipt=source.process(true,left,right,1);});latch.wait();check(source.close()&&source.open(48000,next.sink()),"replace before old lease admitted");latch.release();worker.join();source.testAfterEpoch=nullptr;check(!receipt.admitted&&first.calls==0&&next.calls==0,"old epoch refused");check(source.process(true,left,right,1).stored==1,"new epoch intact");});
 run("failed factory admission stays closed",[&]{PluginSendEndpoint source;Sink sink;check(!source.open(0,sink.sink()),"invalid rate refused");check(!source.ready()&&!source.process(true,left,right,1).admitted,"no fallback");});
 run("memory refusal truthful and never retried",[&]{PluginSendEndpoint source;Sink sink;sink.accept=false;check(source.open(48000,sink.sink()),"open");auto value=source.process(true,left,right,1);check(value.admitted&&value.flushes==1&&value.stored==0,"local refusal");sink.accept=true;source.process(true,left,right,1);check(sink.calls==2,"new block only");});
 run("callback visit does not allocate or retire ownership",[&]{PluginSendEndpoint source;Sink sink;check(source.open(48000,sink.sink()),"control allocates owner");allocations=deallocations=0;counting=true;auto enabled=source.process(true,left,right,1);auto disabled=source.process(false);counting=false;check(enabled.stored==1&&disabled.admitted,"both callback paths");check(allocations==0&&deallocations==0,"callback owns no heap lifetime");check(source.close(),"off callback retirement");});
 run("nested callback cannot retire outer borrowed owner",[&]{PluginSendEndpoint outer,inner;Sink last;last.reenter=&outer;check(inner.open(48000,last.sink()),"inner open");struct Forward{PluginSendEndpoint *inner;static bool write(void *p,const float*l,const float*r,size_t n,float g) noexcept{return static_cast<Forward*>(p)->inner->process(true,l,r,n,g).stored==1;}} forward{&inner};check(outer.open(48000,{&forward,Forward::write}),"outer open");check(outer.process(true,left,right,1).stored==1&&!last.closed&&!outer.ready(),"nested revocation no receipt");check(outer.close()&&inner.close(),"control retires both");});
 run("finite endpoint replacement churn",[&]{PluginSendEndpoint source;Sink sink;for(int i=0;i<200;++i){check(source.open(48000,sink.sink()),"churn open");check(source.process(true,left,right,1).stored==1,"churn stored");check(source.close(),"churn actual retirement");}check(sink.calls==200,"no duplicate visits");});
 std::cout<<"RESULT cases="<<cases<<" assertions="<<assertions<<" failures="<<failures<<'\n';return failures?1:0;
}
