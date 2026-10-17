#include "BridgeProtocol.h"
#include <iostream>
#include <memory>
#include <limits>
#include <stdexcept>
static void check(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
int main() {
    using namespace remsound;
    try {
        const auto p = packet(Kind::hello, 0x12345678, {1, 0, 0, 0});
        check(p == std::vector<uint8_t>(
                       {'R', 'S', 'B', 'R', 1, 1, 4, 0, 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0, 1, 0, 0, 0}),
              "Golden hello changed");
        check(valid(p.data(), p.size(), 0x12345678), "Valid hello rejected");
        for (size_t n = 0; n < p.size(); ++n)
            check(!valid(p.data(), n, 0x12345678), "Truncated hello accepted");
        for (uint8_t kind : {0, 2, 5, 11, 255}) {
            auto bad = p;
            bad[5] = kind;
            check(!valid(bad.data(), bad.size(), 0x12345678), "Retired or unknown message accepted");
        }
        auto observed = packet(Kind(10), 0x12345678,
            {0,0,0,0,0,112,231,64,128,0,0,0});
        check(valid(observed.data(), observed.size(), 0x12345678), "Optional host callback message rejected");
        auto geometry = hostGeometryBody(48000.125, 128);
        check(hostGeometry(geometry.data(), geometry.size())->sampleRate == 48000.125,
              "Host sample rate lost precision");
        check(hostGeometry(geometry.data(), geometry.size())->frames == 128, "Actual callback frames lost");
        for (double rate : {0., 7999., 768001., std::numeric_limits<double>::infinity(),
                            std::numeric_limits<double>::quiet_NaN()})
            check(hostGeometryBody(rate, 128).empty(), "Invalid host rate accepted");
        for (uint32_t frames : {0u, maximumHostFrames + 1, UINT32_MAX})
            check(hostGeometryBody(48000, frames).empty(), "Invalid callback geometry accepted");
        for (size_t n = 0; n < geometry.size(); ++n)
            check(!hostGeometry(geometry.data(), n), "Truncated callback geometry accepted");
        auto fifo = std::make_unique<AudioFifo>();
        std::array<float, 4> l{1, 2, 3, 4}, r{-1, -2, -3, -4}, a{}, b{};
        check(fifo->push(l.data(), r.data(), 4), "FIFO rejected audio");
        check(fifo->pop(a.data(), b.data(), 4) == 4 && a == l && b == r, "FIFO changed channels");
        check(fifo->pop(a.data(), b.data(), 4) == 0 && a[0] == 0 && b[0] == 0, "FIFO underrun not silent");
        for (int i = 0; i < 32768; ++i)
            check(fifo->push(l.data(), r.data(), 4), "FIFO capacity mismatch");
        check(!fifo->push(l.data(), r.data(), 1), "FIFO overflow accepted");
        fifo->trimTo(4);
        check(fifo->available() == 4, "FIFO stale-audio trim failed");
        check(fifo->pop(a.data(), b.data(), 4) == 4 && a == l && b == r,
              "FIFO trim did not keep the newest audio");
        fifo->discard();
        check(fifo->available() == 0, "FIFO discard failed");
        check(bridgePort == 47831 && wireRate == 48000 && wireChannels == 2 && headerSize == 16 &&
                  maxAudioBytes == 32768 && maxBlockFrames == 16384 && roundHeader == 20,
              "Bridge constants changed");
        std::cout << "Bridge protocol and FIFO tests passed\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
