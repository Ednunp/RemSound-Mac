#pragma once
#include "PluginSendBus.h"
#include <memory>
#include <thread>

namespace remsound {
// Control owns open/close; callbacks borrow one stable visit without copying a shared_ptr.
class PluginSendEndpoint {
  public:
    static_assert(std::atomic<unsigned>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free,
        "Callback admission requires lock-free counters");
    static constexpr unsigned maximumCallbackLeases = 64;
    ~PluginSendEndpoint() { close(); }
    bool open(double rate, PluginSendBus::Sink sink, std::shared_ptr<PluginSendBus> verifiedOwner = {}) {
        if (onCallback()) return false;
        std::lock_guard<std::mutex> lock(control);
        if (!retire()) return false;
        if (nextEpoch == std::numeric_limits<uint64_t>::max()) return false;
        try {
            auto next = verifiedOwner ? std::move(verifiedOwner) : std::make_shared<PluginSendBus>();
            auto token = next->attach(rate, sink); if (!token) return false;
            owner = std::move(next); handle = *token; epoch.store(++nextEpoch);
            return true;
        } catch (const std::bad_alloc &) { return false; }
    }
    bool close() {
        epoch.store(0);
        if (onCallback()) return false; // No self-wait or fabricated receipt; control must finish retirement.
        std::lock_guard<std::mutex> lock(control); return retire();
    }
    bool ready() const noexcept { return epoch.load() != 0; }
    PluginSendBus::Receipt process(bool sending, const float *left = nullptr, const float *right = nullptr,
        size_t frames = 0, float gain = 1) noexcept {
        const auto visit = epoch.load(); if (!visit) return {};
#if defined(REMSOUND_TESTING)
        if (testAfterEpoch) testAfterEpoch(testContext);
#endif
        unsigned depth = 0; for (auto *node = callbacks; node; node = node->previous) if (++depth >= maximumCallbackLeases) return {};
        auto count = entered.load();
        if (count >= maximumCallbackLeases || !entered.compare_exchange_strong(count, count + 1)) return {};
        Lease lease(*this);
        if (epoch.load() != visit) return {};
        auto *bus = owner.get();
        auto receipt = bus->setSending(handle, sending);
        if (!sending || !receipt.admitted) return receipt;
        auto write = bus->submit(handle, left, right, frames, gain);
        write.flushes += receipt.flushes; write.stored += receipt.stored; write.partials += receipt.partials;
        return write;
    }
#if defined(REMSOUND_TESTING)
    void (*testAfterEpoch)(void *) = nullptr;
    void *testContext = nullptr;
#endif
  private:
    struct Node { PluginSendEndpoint *owner; Node *previous; };
    inline static thread_local Node *callbacks = nullptr;
    struct Lease {
        PluginSendEndpoint &owner; Node node;
        explicit Lease(PluginSendEndpoint &owner) : owner(owner), node{&owner, callbacks} { callbacks = &node; }
        ~Lease() { callbacks = node.previous; owner.entered.fetch_sub(1); }
    };
    bool onCallback() const noexcept {
        for (auto *node = callbacks; node; node = node->previous) if (node->owner == this) return true;
        return false;
    }
    bool retire() {
        epoch.store(0);
        while (entered.load() != 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (!owner) return true;
        if (!owner->detach(handle).admitted) return false;
        owner.reset(); handle = {}; return true;
    }
    std::mutex control;
    std::shared_ptr<PluginSendBus> owner;
    PluginSendBus::Handle handle{};
    // Callback admission belongs to this Endpoint, independently of a bus's slot IDs.
    uint64_t nextEpoch = 0;
    std::atomic<uint64_t> epoch{0};
    std::atomic<unsigned> entered{0};
};
}
