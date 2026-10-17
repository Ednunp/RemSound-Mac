#pragma once
#include "PluginSendEndpoint.h"

// Test-only ABI: each module compiles the actual production headers with private symbols.
struct PluginSendModuleAPI {
    using Bus = remsound::PluginSendBus;
    using Endpoint = remsound::PluginSendEndpoint;
    void *(*owner)();
    void (*release)(void *);
    Bus *(*bus)(void *);
    size_t (*liveBuses)();
    Bus::Handle (*attach)(Bus *, Bus::Sink);
    bool (*detach)(Bus *, Bus::Handle);
    bool (*enable)(Bus *, Bus::Handle);
    Bus::Receipt (*submit)(Bus *, Bus::Handle, const float *, const float *, size_t);
    Endpoint *(*endpoint)(void *, Bus::Sink);
    bool (*close)(Endpoint *);
    void (*destroyEndpoint)(Endpoint *);
    Bus::Receipt (*process)(Endpoint *, bool, const float *, const float *, size_t);
    Bus *(*construct)(void *);
    void (*destruct)(Bus *);
};
using PluginSendModuleEntry = const PluginSendModuleAPI *(*)();
