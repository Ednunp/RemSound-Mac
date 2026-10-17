#include "PluginSendModuleAPI.h"
#include <dlfcn.h>
#include <iostream>
#include <condition_variable>
#include <future>
using Bus = PluginSendModuleAPI::Bus;
static int cases = 0, assertions = 0, failures = 0;
static void check(bool ok, const char *why) { ++assertions; if (!ok) { ++failures; std::cerr << "FAIL " << why << '\n'; } }
struct Module {
    void *image = nullptr;
    const PluginSendModuleAPI *api = nullptr;
    explicit Module(const char *path) {
        image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!image) { std::cerr << dlerror() << '\n'; return; }
        auto entry = reinterpret_cast<PluginSendModuleEntry>(dlsym(image, "remsoundSendModuleTestAPI"));
        if (entry) api = entry();
    }
    ~Module() { if (image) dlclose(image); }
};
struct Sink {
    size_t calls = 0, frames = 0;
    float left = 0, right = 0;
    std::mutex gate;
    std::condition_variable wake;
    bool hold = false, entered = false, returned = false;
    static bool write(void *p, const float *l, const float *r, size_t n, float gain) noexcept {
        auto &s = *static_cast<Sink *>(p); ++s.calls; s.frames = n; s.left = l[0] * gain; s.right = r[0] * gain;
        if (s.hold) { std::unique_lock<std::mutex> lock(s.gate); s.entered = true; s.wake.notify_all(); s.wake.wait(lock, [&] { return s.returned; }); }
        return true;
    }
    Bus::Sink sink() { return {this, write}; }
};
template<class F> static void run(const char *name, F body) { ++cases; body(); std::cout << "CASE " << name << '\n'; }
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    Module a(argv[1]), b(argv[2]);
    if (!a.api || !b.api || a.image == b.image || a.api == b.api) return 2;
    const auto &A = *a.api; const auto &B = *b.api;
    const float left[] = {0.25f, 0.5f}, right[] = {-0.25f, -0.5f};
    run("different module bus refuses foreign matching slot", [&] {
        void *oa = A.owner(), *ob = B.owner(); auto *ba = A.bus(oa), *bb = B.bus(ob); Sink one, two;
        auto ha = A.attach(ba, one.sink()), hb = B.attach(bb, two.sink());
        check(ha.slot == hb.slot && ha.generation && hb.generation, "matching slot premise");
        check(A.enable(ba, ha) && B.enable(bb, hb), "own handles enable");
        check(!B.submit(bb, ha, left, right, 2).admitted, "foreign module samples refused");
        check(!B.detach(bb, ha), "foreign module cannot detach");
        check(B.submit(bb, hb, left, right, 2).stored == 1 && two.calls == 1, "foreign attempt preserves real owner");
        A.detach(ba, ha); B.detach(bb, hb); A.release(oa); B.release(ob);
        check(A.liveBuses() == 0 && B.liveBuses() == 0, "distinct final release");
    });
    run("verified shared bus sums through independent modules", [&] {
        void *owner = A.owner(); auto *bus = A.bus(owner); Sink one, two;
        auto ha = A.attach(bus, one.sink()), hb = B.attach(bus, two.sink());
        check(ha.generation < hb.generation, "shared bus registration order crosses modules");
        check(A.enable(bus, ha) && B.enable(bus, hb), "shared handles enable");
        check(B.submit(bus, hb, left, right, 2).stored == 0, "secondary awaits contribution");
        check(A.submit(bus, ha, left, right, 2).stored == 1, "one mixed block");
        check(one.calls == 1 && two.calls == 0 && one.frames == 2 && one.left == 0.5f && one.right == -0.5f, "sum and length through actual bus");
        check(B.detach(bus, hb) && A.detach(bus, ha), "both module registrations retire");
        A.release(owner); check(A.liveBuses() == 0, "shared final release");
    });
    run("same address cross module reconstruction refuses old epoch", [&] {
        auto memory = std::make_unique<unsigned char[]>(sizeof(Bus)); Sink sink;
        auto *first = A.construct(memory.get()); auto old = A.attach(first, sink.sink()); A.detach(first, old); A.destruct(first);
        auto *next = B.construct(memory.get()); auto fresh = B.attach(next, sink.sink());
        check(old.slot == fresh.slot && old.generation && fresh.generation, "reconstructed matching slot");
        check(!B.enable(next, old) && !B.detach(next, old), "retired module token refused after reconstruction");
        check(B.enable(next, fresh) && B.submit(next, fresh, left, right, 2).stored == 1, "fresh lifetime works");
        B.detach(next, fresh); B.destruct(next);
    });
    run("endpoint retains shared bus until last module release", [&] {
        void *owner = A.owner(); Sink one, two; auto *ea = A.endpoint(owner, one.sink()), *eb = B.endpoint(owner, two.sink());
        check(ea && eb, "both endpoints opened"); if (!ea || !eb) return;
        A.release(owner); check(A.liveBuses() == 1, "endpoints retain actual bus");
        A.process(ea, true, left, right, 2); B.process(eb, true, left, right, 2); A.process(ea, true, left, right, 2);
        check(one.calls == 2 && two.calls == 0 && one.left == 0.5f, "Endpoint uses same sum path");
        check(A.close(ea), "first endpoint retirement"); A.destroyEndpoint(ea); check(A.liveBuses() == 1, "other module still owns bus");
        check(B.process(eb, true, left, right, 2).stored == 1 && two.calls == 1, "survivor direct path");
        check(B.close(eb), "final endpoint retirement"); B.destroyEndpoint(eb); check(A.liveBuses() == 0, "no retained cross module owner");
    });
    run("cross module close waits actual synchronous sink", [&] {
        void *owner = A.owner(); Sink sink; sink.hold = true; auto *endpoint = B.endpoint(owner, sink.sink()); A.release(owner);
        check(endpoint != nullptr, "blocking endpoint opens"); if (!endpoint) return;
        auto writing = std::async(std::launch::async, [&] { return B.process(endpoint, true, left, right, 2); });
        { std::unique_lock<std::mutex> lock(sink.gate); check(sink.wake.wait_for(lock, std::chrono::seconds(2), [&] { return sink.entered; }), "actual sink entered"); }
        auto closing = std::async(std::launch::async, [&] { return B.close(endpoint); });
        check(closing.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout, "no premature close receipt");
        { std::lock_guard<std::mutex> lock(sink.gate); sink.returned = true; sink.wake.notify_all(); }
        check(writing.get().stored == 1 && closing.get(), "raw write and close return");
        check(!B.process(endpoint, true, left, right, 2).admitted, "retired callback refuses");
        B.destroyEndpoint(endpoint); check(A.liveBuses() == 0, "raw copy no longer owns bus");
    });
    run("cross module bounded replacement releases every bus", [&] {
        for (int i = 0; i < 64; ++i) { void *owner = A.owner(); Sink sink; auto *e = B.endpoint(owner, sink.sink()); A.release(owner); check(e && B.process(e, true, left, right, 2).stored == 1, "bounded fresh visit"); if(e) { check(B.close(e), "actual visit closes"); B.destroyEndpoint(e); } }
        check(A.liveBuses() == 0 && B.liveBuses() == 0, "churn final release");
    });
    run("retired module handle closes and reopens", [&] {
        check(B.liveBuses() == 0, "module has no retained bus before close");
        check(dlclose(b.image) == 0, "actual module handle closes"); b.image = nullptr; b.api = nullptr;
        Module reload(argv[2]); check(reload.api && reload.api->liveBuses() == 0, "reopened module has no prior bus");
        if (!reload.api) return;
        void *owner = reload.api->owner(); Sink sink; auto *endpoint = reload.api->endpoint(owner, sink.sink()); reload.api->release(owner);
        check(endpoint && reload.api->process(endpoint, true, left, right, 2).stored == 1, "fresh endpoint after reopen");
        if (endpoint) { check(reload.api->close(endpoint), "reopened endpoint retires"); reload.api->destroyEndpoint(endpoint); }
        check(reload.api->liveBuses() == 0, "reopened module releases all buses");
    });
    std::cout << "RESULT cases=" << cases << " assertions=" << assertions << " failures=" << failures << '\n'; return failures ? 1 : 0;
}
