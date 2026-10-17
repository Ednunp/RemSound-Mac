#include "PluginHostRuntime.h"
namespace remsound {
std::shared_ptr<PluginSendBus> acquireHostSendBusV1(double rate) {
    if (!std::isfinite(rate) || rate < minimumHostRate || rate > maximumHostRate) return {};
    // This state lives in the one shared native image, never in an AU/VST3/CLAP copy.
    static std::mutex gate;
    static std::weak_ptr<PluginSendBus> current;
    static double currentRate = 0;
    std::lock_guard<std::mutex> lock(gate);
    if (auto bus = current.lock()) return currentRate == rate ? bus : std::shared_ptr<PluginSendBus>{};
    try {
        auto bus = std::make_shared<PluginSendBus>();
        current = bus; currentRate = rate; return bus;
    } catch (const std::bad_alloc &) { return {}; }
}
}
