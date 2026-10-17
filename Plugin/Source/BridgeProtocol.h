#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
#include <optional>
namespace remsound {
#if defined(REMSOUND_TESTING)
inline int bridgePort = 0; // The isolated mock assigns an ephemeral port before starting a processor.
#else
constexpr int bridgePort = 47831;
#endif
constexpr int wireRate = 48000, wireChannels = 2, headerSize = 16;
constexpr int maxAudioBytes = 32768, maxBlockFrames = 16384, maxPeers = 32, roundHeader = 20;
enum class Kind : uint8_t { hello = 1, release = 3, track = 4, goodbye = 6, peers = 7, claim = 8, audio = 9, hostCallback = 10 };
inline uint32_t read32(const uint8_t *p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
inline void put32(std::vector<uint8_t> &d, uint32_t v) {
    for (int i = 0; i < 4; ++i)
        d.push_back(uint8_t(v >> (8 * i)));
}
inline std::vector<uint8_t> packet(Kind kind, uint32_t instance, const std::vector<uint8_t> &body = {}) {
    if (body.size() > maxAudioBytes)
        return {};
    std::vector<uint8_t> d = {
        'R', 'S', 'B', 'R', 1, uint8_t(kind), uint8_t(body.size()), uint8_t(body.size() >> 8)};
    put32(d, instance);
    put32(d, 0);
    d.insert(d.end(), body.begin(), body.end());
    return d;
}
inline bool valid(const uint8_t *p, size_t n, uint32_t instance) {
    if (n < headerSize || std::memcmp(p, "RSBR", 4) || p[4] != 1 || read32(p + 8) != instance)
        return false;
    auto kind = Kind(p[5]);
    if (kind != Kind::hello && kind != Kind::release && kind != Kind::track && kind != Kind::goodbye &&
        kind != Kind::peers && kind != Kind::claim && kind != Kind::audio && kind != Kind::hostCallback)
        return false;
    size_t length = p[6] | (size_t(p[7]) << 8);
    return length <= maxAudioBytes && n == headerSize + length;
}
struct HostGeometry {
    double sampleRate;
    uint32_t frames;
};
constexpr size_t hostGeometryBytes = 12;
constexpr uint32_t maximumHostFrames = 1048576;
constexpr double minimumHostRate = 8000, maximumHostRate = 768000;
inline std::optional<HostGeometry> hostGeometry(const uint8_t *body, size_t size) {
    if (size != hostGeometryBytes)
        return std::nullopt;
    uint64_t bits = uint64_t(read32(body)) | (uint64_t(read32(body + 4)) << 32);
    double rate;
    std::memcpy(&rate, &bits, sizeof(rate));
    const auto frames = read32(body + 8);
    if (!std::isfinite(rate) || rate < minimumHostRate || rate > maximumHostRate || frames == 0 || frames > maximumHostFrames)
        return std::nullopt;
    return HostGeometry{rate, frames};
}
// Allocated only on the worker. Callback code publishes one lock-free frame count.
inline std::vector<uint8_t> hostGeometryBody(double rate, uint32_t frames) {
    uint64_t bits;
    std::memcpy(&bits, &rate, sizeof(bits));
    std::vector<uint8_t> body;
    put32(body, uint32_t(bits));
    put32(body, uint32_t(bits >> 32));
    put32(body, frames);
    return hostGeometry(body.data(), body.size()) ? body : std::vector<uint8_t>{};
}
// Exactly one producer and one consumer. Dropping a full block never advances the other side's cursor.
class AudioFifo {
    static constexpr uint64_t capacity = 131072;
    std::array<float, capacity * 2> data{};
    alignas(64) std::atomic<uint64_t> writeIndex{0};
    alignas(64) std::atomic<uint64_t> readIndex{0};

  public:
    size_t available() const {
        return size_t(writeIndex.load(std::memory_order_acquire) - readIndex.load(std::memory_order_acquire));
    }
    bool push(const float *left, const float *right, size_t n, float gain = 1) {
        auto w = writeIndex.load(std::memory_order_relaxed), r = readIndex.load(std::memory_order_acquire);
        if (n > capacity - (w - r))
            return false;
        for (size_t i = 0; i < n; ++i) {
            auto p = ((w + i) % capacity) * 2;
            data[p] = std::isfinite(left[i]) ? left[i] * gain : 0;
            data[p + 1] = std::isfinite(right[i]) ? right[i] * gain : 0;
        }
        writeIndex.store(w + n, std::memory_order_release);
        return true;
    }
    size_t pop(float *left, float *right, size_t n) {
        auto r = readIndex.load(std::memory_order_relaxed), w = writeIndex.load(std::memory_order_acquire);
        auto count = std::min<uint64_t>(n, w - r);
        for (size_t i = 0; i < n; ++i) {
            auto p = ((r + i) % capacity) * 2;
            left[i] = i < count ? data[p] : 0;
            right[i] = i < count ? data[p + 1] : 0;
        }
        readIndex.store(r + count, std::memory_order_release);
        return size_t(count);
    }
    void discard() {
        readIndex.store(writeIndex.load(std::memory_order_acquire), std::memory_order_release);
    }
    bool trimTo(size_t remaining) {
        auto r = readIndex.load(std::memory_order_relaxed);
        auto w = writeIndex.load(std::memory_order_acquire);
        if (w - r <= remaining)
            return false;
        readIndex.store(w - remaining, std::memory_order_release);
        return true;
    }
};
} // namespace remsound
