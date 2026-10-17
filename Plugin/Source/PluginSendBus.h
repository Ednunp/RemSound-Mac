#pragma once
#include "BridgeProtocol.h"
#include <limits>
#include <mutex>
#include <cstdlib>

namespace remsound {
// Construct/register/detach off the audio callback. A sink may only copy synchronously into bounded memory.
class PluginSendBus {
  public:
    static constexpr size_t maximumSenders = 64;
    using Incarnation = std::array<uint64_t, 2>;
    struct Handle { size_t slot; uint64_t generation; Incarnation incarnation{}; };
    struct Sink { void *context; bool (*write)(void *, const float *, const float *, size_t, float) noexcept; };
    struct Receipt { bool admitted = false; size_t flushes = 0, stored = 0, partials = 0; };
    struct Snapshot { size_t attached = 0, active = 0, contributed = 0, frames = 0; };
    std::optional<Handle> attach(double rate, Sink sink) {
        if (!std::isfinite(rate) || rate < minimumHostRate || rate > maximumHostRate || !sink.write || incarnation == Incarnation{}) return {};
        std::lock_guard<std::recursive_mutex> lock(gate);
        if (inSink || (attached && rate != sampleRate)) return {};
        for (size_t i = 0; i < maximumSenders; ++i) if (!slots[i].generation) {
            const auto generation = reserveGeneration(); if (!generation) return {};
            auto &slot = slots[i]; slot = {generation, sink, false, false};
            ++attached; sampleRate = rate; return Handle{i, slot.generation, incarnation};
        }
        return {};
    }
    Receipt detach(Handle handle) {
        std::lock_guard<std::recursive_mutex> lock(gate);
        if (inSink) return {};
        auto *slot = find(handle); if (!slot) return {};
        Receipt receipt{true}; deactivate(handle.slot, receipt); *slot = {}; --attached;
        if (!attached) sampleRate = 0;
        return receipt; // The lock includes every sink copy: no use of this sink survives detach.
    }
    Receipt setSending(Handle handle, bool enabled) noexcept {
        std::unique_lock<std::recursive_mutex> lock(gate, std::try_to_lock);
        if (!lock.owns_lock() || inSink) return {};
        auto *slot = find(handle); if (!slot) return {};
        Receipt receipt{true};
        if (slot->active == enabled) return receipt;
        if (!enabled) deactivate(handle.slot, receipt);
        else { slot->active = true; ++active; if (leader == maximumSenders) leader = handle.slot; }
        return receipt;
    }
    Receipt submit(Handle handle, const float *left, const float *right, size_t count, float gain = 1) noexcept {
        if (!count || count > maxBlockFrames || !left || !right || !std::isfinite(gain)) return {};
        std::unique_lock<std::recursive_mutex> lock(gate, std::try_to_lock);
        if (!lock.owns_lock() || inSink) return {};
        auto *slot = find(handle); if (!slot || !slot->active) return {};
        Receipt receipt{true};
        if (active == 1 && !frames) {
            // The ordinary path keeps the original block and gain. The sink owns its bounded copy/sanitization.
            receipt.flushes = 1; receipt.stored = store(slot->sink, left, right, count, gain) ? 1 : 0;
            return receipt;
        }
        if (slot->contributed) flush(receipt, true);
        for (size_t i = 0; i < count; ++i) {
            const double l = std::isfinite(left[i]) ? double(left[i]) * gain : 0;
            const double r = std::isfinite(right[i]) ? double(right[i]) * gain : 0;
            if (i < frames) { sumLeft[i] += l; sumRight[i] += r; }
            else { sumLeft[i] = l; sumRight[i] = r; }
        }
        frames = std::max(frames, count); slot->contributed = true; ++contributed;
        if (contributed >= active) flush(receipt, false);
        return receipt;
    }
    Snapshot snapshot() {
        std::lock_guard<std::recursive_mutex> lock(gate); return {attached, active, contributed, frames};
    }

  private:
    struct Slot { uint64_t generation = 0; Sink sink{}; bool active = false, contributed = false; };
    // Recursive locking is defined for a same-thread sink callback; inSink refuses its mutations.
    std::recursive_mutex gate;
    bool inSink = false;
    std::array<Slot, maximumSenders> slots{};
    std::array<double, maxBlockFrames> sumLeft{}, sumRight{};
    std::array<float, maxBlockFrames> outputLeft{}, outputRight{};
    // Hidden AU/VST/CLAP modules can each start their registration counter at one.
    // A control-time nonce fences foreign and reconstructed buses across those modules.
    const Incarnation incarnation = [] { Incarnation value{}; arc4random_buf(value.data(), sizeof(value)); return value; }();
    uint64_t nextGeneration = 0;
    size_t attached = 0, active = 0, contributed = 0, frames = 0, leader = maximumSenders;
    double sampleRate = 0;
    uint64_t reserveGeneration() {
        // attach already holds this bus's gate, including calls from another module.
        if (nextGeneration == std::numeric_limits<uint64_t>::max()) return 0;
        return ++nextGeneration;
    }
    Slot *find(Handle handle) noexcept {
        return handle.incarnation == incarnation && handle.slot < maximumSenders && handle.generation && slots[handle.slot].generation == handle.generation
            ? &slots[handle.slot] : nullptr;
    }
    void clearRound() noexcept {
        frames = 0; contributed = 0; for (auto &slot : slots) slot.contributed = false;
    }
    void deactivate(size_t index, Receipt &receipt) noexcept {
        auto &slot = slots[index]; if (!slot.active) return;
        slot.active = false; --active;
        if (slot.contributed) { slot.contributed = false; --contributed; }
        if (!active) { clearRound(); leader = maximumSenders; return; }
        if (leader == index) {
            leader = maximumSenders;
            for (size_t i = 0; i < maximumSenders; ++i) if (slots[i].active &&
                (leader == maximumSenders || slots[i].generation < slots[leader].generation)) leader = i;
        }
        if (contributed >= active) flush(receipt, false);
    }
    static float finiteFloat(double value) noexcept {
        const double limit = std::numeric_limits<float>::max();
        return float(std::max(-limit, std::min(limit, value)));
    }
    bool store(Sink &sink, const float *left, const float *right, size_t count, float gain) noexcept {
        inSink = true;
        const bool stored = sink.write(sink.context, left, right, count, gain);
        inSink = false;
        return stored;
    }
    void flush(Receipt &receipt, bool partial) noexcept {
        const auto count = frames; clearRound(); if (!count || leader == maximumSenders) return;
        for (size_t i = 0; i < count; ++i) { outputLeft[i] = finiteFloat(sumLeft[i]); outputRight[i] = finiteFloat(sumRight[i]); }
        ++receipt.flushes; if (partial) ++receipt.partials;
        auto &sink = slots[leader].sink;
        if (store(sink, outputLeft.data(), outputRight.data(), count, 1)) ++receipt.stored;
    }
};
}
