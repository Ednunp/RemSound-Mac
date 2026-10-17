#include "PluginSendModuleAPI.h"
using Bus = PluginSendModuleAPI::Bus;
using Endpoint = PluginSendModuleAPI::Endpoint;
static size_t living = 0;
static const PluginSendModuleAPI api {
    []() -> void * { auto p = std::shared_ptr<Bus>(new Bus, [](Bus *b) { delete b; --living; }); ++living; return new std::shared_ptr<Bus>(std::move(p)); },
    [](void *p) { delete static_cast<std::shared_ptr<Bus> *>(p); },
    [](void *p) { return static_cast<std::shared_ptr<Bus> *>(p)->get(); },
    [] { return living; },
    [](Bus *b, Bus::Sink s) { return b->attach(48000, s).value_or(Bus::Handle{}); },
    [](Bus *b, Bus::Handle h) { return b->detach(h).admitted; },
    [](Bus *b, Bus::Handle h) { return b->setSending(h, true).admitted; },
    [](Bus *b, Bus::Handle h, const float *l, const float *r, size_t n) { return b->submit(h, l, r, n); },
    [](void *p, Bus::Sink s) -> Endpoint * { auto e = std::make_unique<Endpoint>(); if (!e->open(48000, s, *static_cast<std::shared_ptr<Bus> *>(p))) return nullptr; return e.release(); },
    [](Endpoint *e) { return e->close(); },
    [](Endpoint *e) { delete e; },
    [](Endpoint *e, bool sending, const float *l, const float *r, size_t n) { return e->process(sending, l, r, n); },
    [](void *p) { return new(p) Bus; },
    [](Bus *b) { b->~Bus(); }
};
extern "C" __attribute__((visibility("default"))) const PluginSendModuleAPI *remsoundSendModuleTestAPI() { return &api; }
