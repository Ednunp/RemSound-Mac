#include "PluginSendBus.h"
#include <atomic>
#include <condition_variable>
#include <iostream>
#include <limits>
#include <memory>
#include <thread>
#include <future>
#include <cstdlib>
#include <new>
#include <string_view>

using namespace remsound;
static int failures = 0, assertions = 0, cases = 0;
static std::string_view filter;
static thread_local bool countAllocations = false;
static thread_local size_t allocations = 0;
void *operator new(std::size_t size) { if(countAllocations) ++allocations; if(auto *p=std::malloc(size ? size : 1)) return p; throw std::bad_alloc(); }
void *operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
static void check(bool value, const char *message) {
    ++assertions; if (!value) { ++failures; std::cerr << "FAIL " << message << '\n'; }
}
struct Output {
    size_t calls = 0, frames = 0;
    std::array<float, maxBlockFrames> left{}, right{};
    bool accepts = true;
    PluginSendBus *reenter = nullptr;
    PluginSendBus::Handle handle{};
    bool reentered = true;
    bool controlReentry = false, controlAdmitted = false;
    std::mutex gate; std::condition_variable condition;
    bool hold = false, entered = false, released = false;
    static bool write(void *context, const float *l, const float *r, size_t n, float gain) noexcept {
        auto &self = *static_cast<Output *>(context); ++self.calls; self.frames = n;
        if (n > maxBlockFrames) return false; // Keep a planted cap omission from overrunning the fixture itself.
        for (size_t i = 0; i < n; ++i) { self.left[i] = std::isfinite(l[i]) ? l[i] * gain : 0; self.right[i] = std::isfinite(r[i]) ? r[i] * gain : 0; }
        if (self.reenter) self.reentered = self.reenter->submit(self.handle, l, r, n).admitted;
        if (self.controlReentry) self.controlAdmitted = self.reenter->detach(self.handle).admitted
            || self.reenter->setSending(self.handle, false).admitted || self.reenter->attach(48000,self.sink()).has_value();
        if (self.hold) {
            std::unique_lock<std::mutex> lock(self.gate); self.entered = true; self.condition.notify_all();
            self.condition.wait_for(lock, std::chrono::seconds(2), [&] { return self.released; });
        }
        return self.accepts;
    }
    PluginSendBus::Sink sink() { return {this, write}; }
};
struct Fixture {
    std::unique_ptr<PluginSendBus> bus = std::make_unique<PluginSendBus>();
    std::unique_ptr<Output> a = std::make_unique<Output>(), b = std::make_unique<Output>();
    PluginSendBus::Handle one{}, two{};
    bool add(bool second = false) {
        auto first = bus->attach(48000, a->sink()); check(first.has_value(), "first registration"); if (!first) return false; one = *first;
        check(bus->setSending(one, true).admitted, "first sending");
        if (second) { auto next = bus->attach(48000, b->sink()); check(next.has_value(), "second registration"); if (!next) return false; two = *next; check(bus->setSending(two, true).admitted, "second sending"); }
        return true;
    }
};
template<class F> static void run(const char *name, F body) { if(!filter.empty() && std::string_view(name).find(filter)==std::string_view::npos) return; ++cases; body(); std::cout << "CASE " << name << '\n'; }
int main(int argc, char **argv) {
    if(argc>2) return 2;
    if(argc>1) filter=argv[1];
    const float l[] = {0.25f, 0.5f, 0.75f}, r[] = {-0.25f, -0.5f, -0.75f};
    run("single direct preserves scale and length", [&] { Fixture f; if (!f.add()) return; auto receipt=f.bus->submit(f.one,l,r,3,2); check(receipt.admitted && receipt.flushes==1 && receipt.stored==1,"direct receipt"); check(f.a->frames==3 && f.a->left[2]==1.5f && f.a->right[0]==-0.5f,"no audio-level clamp"); check(f.bus->snapshot().frames==0,"single has no partial queue"); });
    run("aligned tracks summed once on leader", [&] { Fixture f; if (!f.add(true)) return; check(f.bus->submit(f.two,l,r,3).flushes==0,"secondary waits"); auto receipt=f.bus->submit(f.one,l,r,3); check(receipt.stored==1 && f.a->calls==1 && f.b->calls==0,"one leader sink"); check(f.a->left[2]==1.5f && f.a->right[2]==-1.5f,"sum not concatenation"); });
    run("repeat contributor flushes partial without waiting", [&] { Fixture f; if (!f.add(true)) return; f.bus->submit(f.one,l,r,3); auto receipt=f.bus->submit(f.one,l,r,2); check(receipt.partials==1 && receipt.stored==1,"partial flush"); check(f.a->frames==3,"prior block preserved"); f.bus->submit(f.two,l,r,2); check(f.a->calls==2 && f.a->frames==2,"new round completes"); });
    run("unequal lengths retain longer tail", [&] { Fixture f; if (!f.add(true)) return; f.bus->submit(f.one,l,r,1); f.bus->submit(f.two,l,r,3); check(f.a->frames==3 && f.a->left[0]==0.5f && f.a->left[2]==0.75f,"long secondary tail"); });
    run("short contributor does not erase accumulated tail", [&] { Fixture f; if (!f.add(true)) return; f.bus->submit(f.one,l,r,3); f.bus->submit(f.two,l,r,1); check(f.a->frames==3 && f.a->left[2]==0.75f,"short tail silence"); });
    run("disabled slot is not a sending participant", [&] { Fixture f; if (!f.add(true)) return; check(f.bus->setSending(f.two,false).admitted,"disable"); f.bus->submit(f.one,l,r,1); check(f.a->calls==1,"one active bypass"); check(!f.bus->submit(f.two,l,r,1).admitted,"disabled refuses"); });
    run("leaving preserves already contributed audio", [&] { Fixture f; if (!f.add(true)) return; f.bus->submit(f.one,l,r,1); f.bus->submit(f.two,l,r,1); f.bus->submit(f.one,l,r,1); f.bus->detach(f.one); f.bus->submit(f.two,l,r,1); check(f.b->calls==1 && f.b->left[0]==0.5f,"old contribution retained on new leader"); });
    run("last sender clears partial round", [&] { Fixture f; if (!f.add(true)) return; f.bus->submit(f.one,l,r,3); f.bus->setSending(f.one,false); f.bus->setSending(f.two,false); check(f.bus->snapshot().frames==0,"no stale queued round"); f.bus->setSending(f.two,true); f.bus->submit(f.two,l,r,1); check(f.b->frames==1 && f.b->left[0]==0.25f,"new activity is fresh"); });
    run("stale token cannot control reused slot", [&] { Fixture f; if (!f.add()) return; f.bus->detach(f.one); auto fresh=f.bus->attach(48000,f.b->sink()); check(fresh.has_value(),"replacement"); if (!fresh) return; check(fresh->generation!=f.one.generation,"unique generation"); f.bus->setSending(*fresh,true); check(!f.bus->detach(f.one).admitted && !f.bus->setSending(f.one,false).admitted,"old cannot retire replacement"); check(f.bus->submit(*fresh,l,r,1).stored==1,"replacement intact"); });
    run("cap rejects before dereferencing inputs", [&] { Fixture f; if (!f.add()) return; check(!f.bus->submit(f.one,l,r,maxBlockFrames+1).admitted,"oversize before access"); check(!f.bus->submit(f.one,nullptr,nullptr,1).admitted,"nil input"); check(!f.bus->submit(f.one,l,r,0).admitted,"empty input"); check(!f.bus->submit(f.one,l,r,1,std::numeric_limits<float>::infinity()).admitted,"nonfinite gain"); check(f.a->calls==0,"no output"); });
    run("bounded sender inventory refuses overflow", [&] { Fixture f; size_t added=0; for(size_t i=0;i<PluginSendBus::maximumSenders;++i) if(f.bus->attach(48000,f.a->sink())) ++added; check(added==PluginSendBus::maximumSenders,"fixed inventory fills"); check(!f.bus->attach(48000,f.a->sink()),"inventory cap"); check(f.bus->snapshot().attached==PluginSendBus::maximumSenders,"no extra slot"); });
    run("one bus refuses incompatible native clocks", [&] { Fixture f; check(!f.bus->attach(0,f.a->sink()),"invalid clock"); auto first=f.bus->attach(48000,f.a->sink()); check(first.has_value(),"known clock"); check(!f.bus->attach(44100,f.b->sink()),"different clocks do not sum"); if(first) f.bus->detach(*first); check(f.bus->attach(44100,f.b->sink()).has_value(),"empty bus new rate"); });
    run("refused memory write never replays", [&] { Fixture f; if(!f.add(true)) return; f.a->accepts=false; f.bus->submit(f.one,l,r,1); auto result=f.bus->submit(f.two,l,r,1); check(result.flushes==1 && result.stored==0,"refusal truthful"); f.a->accepts=true; f.bus->submit(f.one,l,r,1); f.bus->submit(f.two,l,r,1); check(f.a->calls==2 && f.a->left[0]==0.5f,"no stale retry"); });
    run("reentrant callback admission refuses without deadlock", [&] { Fixture f; if(!f.add()) return; f.a->reenter=f.bus.get(); f.a->handle=f.one; check(f.bus->submit(f.one,l,r,1).stored==1,"outer completes"); check(!f.a->reentered,"inner refuses"); });
    run("busy callback never waits for other callback", [&] { Fixture f; if(!f.add()) return; f.a->hold=true; std::thread worker([&]{ f.bus->submit(f.one,l,r,1); }); {std::unique_lock<std::mutex> lock(f.a->gate); check(f.a->condition.wait_for(lock,std::chrono::seconds(2),[&]{return f.a->entered;}),"owned callback entered");} check(!f.bus->submit(f.one,l,r,1).admitted,"busy refuses"); {std::lock_guard<std::mutex> lock(f.a->gate); f.a->released=true;} f.a->condition.notify_all(); worker.join(); check(f.a->calls==1,"one output"); });
    run("maximum block and bounded native churn", [&] { Fixture f; if(!f.add(true)) return; std::array<float,maxBlockFrames> data{}; data.fill(0.125f); for(int round=0;round<200;++round) { f.bus->submit(f.one,data.data(),data.data(),data.size()); check(f.bus->submit(f.two,data.data(),data.data(),data.size()).stored==1,"bounded round"); } check(f.a->calls==200 && f.a->frames==maxBlockFrames && f.a->left.back()==0.25f,"full cap and stable rounds"); });
    run("sink cannot retire or mutate itself while copying", [&] { Fixture f; if(!f.add()) return; f.a->reenter=f.bus.get(); f.a->handle=f.one; f.a->controlReentry=true; check(f.bus->submit(f.one,l,r,1).stored==1,"outer sink stored"); check(!f.a->controlAdmitted,"reentrant control refused"); check(f.bus->snapshot().attached==1 && f.bus->snapshot().active==1,"lifetime retained"); });
    run("detach waits the actual in-flight sink copy", [&] { Fixture f; if(!f.add()) return; f.a->hold=true; std::thread worker([&]{f.bus->submit(f.one,l,r,1);}); {std::unique_lock<std::mutex> lock(f.a->gate); check(f.a->condition.wait_for(lock,std::chrono::seconds(2),[&]{return f.a->entered;}),"copy entered");} std::promise<void> entered; auto begun=entered.get_future(); auto detached=std::async(std::launch::async,[&]{entered.set_value();return f.bus->detach(f.one).admitted;}); begun.wait(); check(detached.wait_for(std::chrono::milliseconds(5))==std::future_status::timeout,"no invented quiescence"); {std::lock_guard<std::mutex> lock(f.a->gate);f.a->released=true;} f.a->condition.notify_all(); worker.join(); check(detached.get(),"detach completes after copy"); check(!f.bus->submit(f.one,l,r,1).admitted,"old callback fenced"); });
    run("summed nonfinite samples and arithmetic stay finite", [&] { Fixture f; if(!f.add(true)) return; float bad[]={std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::max()}; f.bus->submit(f.one,bad,bad,2,2); f.bus->submit(f.two,bad,bad,2,2); check(f.a->left[0]==0 && f.a->right[0]==0,"nonfinite input silence"); check(std::isfinite(f.a->left[1]) && f.a->left[1]==std::numeric_limits<float>::max(),"finite numeric saturation not wrap"); });
    run("callback paths allocate no C++ heap objects", [&] { Fixture f; if(!f.add(true)) return; allocations=0; countAllocations=true; f.bus->submit(f.one,l,r,3); f.bus->submit(f.two,l,r,3); f.bus->setSending(f.two,false); f.bus->submit(f.one,l,r,3); countAllocations=false; check(allocations==0,"no operator-new calls during callback work"); });
    run("foreign bus handle cannot mutate matching slot", [&] { Fixture f, other; if(!f.add() || !other.add()) return; check(!other.bus->submit(f.one,l,r,1).admitted,"foreign samples refused"); check(!other.bus->detach(f.one).admitted,"foreign retirement refused"); check(other.bus->submit(other.one,l,r,1).stored==1,"actual owner remains valid"); check(other.a->calls==1,"no foreign output"); });
    run("same-address reconstructed bus refuses retired handles", [&] { struct alignas(PluginSendBus) Storage { unsigned char bytes[sizeof(PluginSendBus)]; }; auto memory=std::make_unique<Storage>(); auto sink=std::make_unique<Output>(); auto *bus=new(memory->bytes) PluginSendBus(); auto first=bus->attach(48000,sink->sink()); check(first.has_value(),"first storage lifetime"); if(!first) {bus->~PluginSendBus();return;} bus->detach(*first); bus->~PluginSendBus(); bus=new(memory->bytes) PluginSendBus(); auto next=bus->attach(48000,sink->sink()); check(next.has_value(),"reconstructed lifetime"); if(next) {check(first->incarnation!=next->incarnation,"new bus incarnation"); check(!bus->setSending(*first,true).admitted,"old address not authority");} bus->~PluginSendBus(); });
    if(!cases) check(false,"No selected test cases");
    std::cout << "RESULT cases=" << cases << " assertions=" << assertions << " failures=" << failures << '\n';
    return failures ? 1 : 0;
}
