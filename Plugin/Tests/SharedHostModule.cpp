#include "SharedHostModuleAPI.h"
#include "BridgeClient.h"
static const SharedHostModuleAPI api {
    [](double rate, int port) -> void * { remsound::bridgePort=port; auto c=std::make_unique<BridgeClient>(); c->start(rate); return c.release(); },
    [](void *p) { return static_cast<BridgeClient *>(p)->trackSendingReady(); },
    [](void *p) { return static_cast<BridgeClient *>(p)->connected.load(); },
    [](void *p, float value, size_t frames) { auto &c=*static_cast<BridgeClient *>(p); std::array<float,480> l{},r{}; l.fill(value); r.fill(-value); c.active=true; c.sendEnabled=true; c.audioTicks.fetch_add(1); c.submitTrack(true,l.data(),r.data(),std::min(frames,l.size())); },
    [](void *p) { static_cast<BridgeClient *>(p)->stop(); },
    [](void *p) { delete static_cast<BridgeClient *>(p); }
};
extern "C" __attribute__((visibility("default"))) const SharedHostModuleAPI *remsoundSharedHostTestAPI() { return &api; }
