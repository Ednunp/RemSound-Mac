#pragma once
#include "PluginSendBus.h"
#include <memory>
namespace remsound {
// Internal native ABI. Bump the library ABI name if Bus/Handle layout or ownership changes.
__attribute__((visibility("default"))) std::shared_ptr<PluginSendBus> acquireHostSendBusV1(double rate);
}
