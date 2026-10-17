#include "BridgeProtocol.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <iostream>
#include <juce_audio_utils/juce_audio_utils.h>
#include <memory>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
extern juce::AudioProcessor *JUCE_CALLTYPE createPluginFilter();
static void check(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
static void parameter(juce::AudioProcessor &p, const char *id, float value) {
    for (auto *base : p.getParameters())
        if (auto *param = dynamic_cast<juce::RangedAudioParameter *>(base); param && param->paramID == id) {
            param->setValueNotifyingHost(param->convertTo0to1(value));
            return;
        }
    throw std::runtime_error("Missing parameter");
}
struct MockApp {
    std::atomic<bool> exit{false}, reordered{false}, badClaim{false};
    std::atomic<int> sentFrames{0};
    std::atomic<bool> badAudio{false};
    std::atomic<uint32_t> hostFrames{0};
    std::atomic<uint64_t> hostRateBits{0};
    std::thread thread;
    int fd;
    MockApp() {
        fd = socket(AF_INET, SOCK_DGRAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = htons(remsound::bridgePort);
        if (bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a)) != 0) {
            close(fd);
            throw std::runtime_error("Loopback test port is already in use; close RemSound before testing");
        }
        socklen_t addressSize = sizeof(a);
        if (getsockname(fd, reinterpret_cast<sockaddr*>(&a), &addressSize) != 0)
            throw std::runtime_error("Cannot read the isolated mock port");
        remsound::bridgePort = ntohs(a.sin_port);
        fcntl(fd, F_SETFL, O_NONBLOCK);
        thread = std::thread([this] { run(); });
    }
    ~MockApp() {
        exit = true;
        if (thread.joinable())
            thread.join();
        close(fd);
    }
    void run() {
        using namespace remsound;
        std::array<uint8_t, 65536> d{};
        int64_t round = 0;
        uint64_t phase = 0;
        while (!exit) {
            sockaddr_in from{};
            socklen_t n = sizeof(from);
            auto length = recvfrom(fd, d.data(), d.size(), 0, reinterpret_cast<sockaddr *>(&from), &n);
            if (length < 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            if (length < 16)
                continue;
            uint32_t instance = read32(d.data() + 8);
            if (!valid(d.data(), size_t(length), instance))
                continue;
            std::vector<uint8_t> body;
            Kind reply = Kind::peers;
            auto kind = Kind(d[5]);
            if (kind == Kind::hello) {
                const std::string peers =
                    reordered.load() ? "192.0.2.2\tNew peer\n192.0.2.1\tTest peer" : "192.0.2.1\tTest peer";
                body.assign(peers.begin(), peers.end());
            } else if (kind == Kind::hostCallback) {
                if (auto geometry = hostGeometry(d.data() + headerSize, size_t(length) - headerSize)) {
                    uint64_t bits;
                    std::memcpy(&bits, &geometry->sampleRate, sizeof(bits));
                    hostRateBits.store(bits);
                    hostFrames.store(geometry->frames);
                }
                continue;
            } else if (kind == Kind::track) {
                for (size_t i = 16; i + 4 <= size_t(length); i += 4) {
                    uint32_t bits = read32(d.data() + i);
                    float sample;
                    std::memcpy(&sample, &bits, 4);
                    if (!std::isfinite(sample) || std::abs(sample) > 0.51f)
                        badAudio = true;
                }
                sentFrames += (int(length) - 16) / 8;
                continue;
            } else if (kind == Kind::claim) {
                if (length < 25)
                    continue;
                const uint32_t frames = read32(d.data() + 16);
                const int count = d[20];
                if (frames > 16384 || size_t(length) < 25 + size_t(count) * 4)
                    continue;
                if (count != 1 || d[21] != 192 || d[22] != 0 || d[23] != 2 || d[24] != 1)
                    badClaim = true;
                put32(body, uint32_t(round));
                put32(body, uint32_t(uint64_t(round) >> 32));
                ++round;
                put32(body, read32(d.data() + 21 + count * 4));
                put32(body, 0);
                put32(body, frames * 2);
                for (uint32_t i = 0; i < frames; ++i) {
                    const float value = float(
                        0.1 * std::sin(2 * juce::MathConstants<double>::pi * 1000 * double(phase++) / 48000));
                    uint32_t bits;
                    std::memcpy(&bits, &value, 4);
                    put32(body, bits);
                    put32(body, bits);
                }
                reply = Kind::audio;
            } else
                continue;
            auto packetBytes = packet(reply, instance, body);
            sendto(fd, packetBytes.data(), packetBytes.size(), 0, reinterpret_cast<sockaddr *>(&from), n);
        }
    }
};
int main() {
    juce::ScopedJuceInitialiser_GUI init;
    try {
        MockApp mock;
        for (double rate : {44100., 48000., 96000.})
            for (int block : {64, 256, 4096, 8192}) {
                mock.reordered = false;
                mock.hostFrames = 0;
                mock.hostRateBits = 0;
                std::unique_ptr<juce::AudioProcessor> p(createPluginFilter());
                p->setRateAndBufferSizeDetails(rate, block);
                p->prepareToPlay(rate, block);
                parameter(*p, "send", 1);
                parameter(*p, "receive", 1);
                parameter(*p, "all", 0);
                juce::MemoryBlock state;
                p->getStateInformation(state);
                check(state.getSize() > 0, "No saved state");
                parameter(*p, "send", 0);
                p->setStateInformation(state.getData(), int(state.getSize()));
                juce::AudioBuffer<float> audio(2, block);
                juce::MidiBuffer midi;
                int nonzero = 0, observed = 0, crossings = 0;
                float previous = 0;
                const int blocks = int(rate * 1.4 / block) + 1;
                auto start = std::chrono::steady_clock::now();
                for (int k = 0; k < blocks; ++k) {
                    if (k * block > rate * 0.7)
                        mock.reordered = true;
                    for (int i = 0; i < block; ++i) {
                        audio.setSample(0, i, 0.25f);
                        audio.setSample(1, i, -0.25f);
                    }
                    p->processBlock(audio, midi);
                    if (k * block > rate * 0.5) {
                        for (int i = 0; i < block; ++i) {
                            float v = audio.getSample(0, i) - 0.25f;
                            check(std::isfinite(v), "Nonfinite output");
                            if (std::abs(v) > 0.005f)
                                ++nonzero;
                            if (previous <= 0 && v > 0)
                                ++crossings;
                            previous = v;
                            ++observed;
                        }
                    }
                    std::this_thread::sleep_until(
                        start + std::chrono::microseconds(int64_t((k + 1) * block / rate * 1000000)));
                }
                p->getStateInformation(state);
                check(juce::AudioProcessor::getXmlFromBinary(state.getData(), int(state.getSize()))
                              ->getStringAttribute("selectedPeerAddress") == "192.0.2.1",
                      "Selected address not saved with the project");
                p->releaseResources();
                const auto bits = mock.hostRateBits.load();
                double observedRate;
                std::memcpy(&observedRate, &bits, sizeof(observedRate));
                check(mock.hostFrames == uint32_t(block) && observedRate == rate,
                      "Worker did not report actual processBlock geometry independently of its240-frame claim");
                check(observed > 0 && double(nonzero) / observed > 0.55, "Receive audio mostly silent");
                const double frequency = crossings * rate / observed;
                if (!(frequency > 920 && frequency < 1080))
                    std::cerr << "Pitch diagnostic: rate " << rate << ", block " << block
                              << ", measured " << frequency << " Hz, crossings " << crossings
                              << ", observed " << observed << ", nonzero " << nonzero << '\n';
                check(frequency > 920 && frequency < 1080, "Receive pitch changed across sample rates");
                std::cout << "Passed rate " << rate << ", block " << block << ", measured tone " << frequency
                          << " Hz\n";
            }
        {
            mock.reordered = false;
            std::unique_ptr<juce::AudioProcessor> p(createPluginFilter());
            constexpr int block = 256;
            constexpr double rate = 48000;
            p->setRateAndBufferSizeDetails(rate, block);
            p->prepareToPlay(rate, block);
            parameter(*p, "all", 0);
            juce::AudioBuffer<float> audio(2, block);
            juce::MidiBuffer midi;
            auto runBlocks = [&](int blocks, bool expectPeerAudio) {
                bool heardPeer = false;
                auto start = std::chrono::steady_clock::now();
                for (int k = 0; k < blocks; ++k) {
                    for (int i = 0; i < block; ++i) {
                        audio.setSample(0, i, 0.25f);
                        audio.setSample(1, i, -0.25f);
                    }
                    p->processBlock(audio, midi);
                    for (int i = 0; i < block; ++i) {
                        const float delta = audio.getSample(0, i) - 0.25f;
                        if (std::abs(delta) > 0.005f)
                            heardPeer = true;
                    }
                    std::this_thread::sleep_until(
                        start + std::chrono::microseconds(int64_t((k + 1) * block / rate * 1000000)));
                }
                check(heardPeer == expectPeerAudio, "Track Receive switch did not control track audio");
            };
            runBlocks(100, false);
            parameter(*p, "receive", 1);
            runBlocks(200, true);
            parameter(*p, "receive", 0);
            runBlocks(40, false);
            p->releaseResources();
        }
        {
            mock.hostFrames = 0;
            std::unique_ptr<juce::AudioProcessor> p(createPluginFilter());
            p->setRateAndBufferSizeDetails(48000, 4096);
            p->prepareToPlay(48000, 4096);
            std::this_thread::sleep_for(std::chrono::milliseconds(1200));
            check(mock.hostFrames == 0, "Prepare size was misreported before any processBlock callback");
            juce::MidiBuffer midi;
            for (int actualFrames : {96, 32}) {
                juce::AudioBuffer<float> block(2, actualFrames);
                block.clear();
                const auto began = std::chrono::steady_clock::now();
                const auto until = began + std::chrono::milliseconds(1200);
                while (std::chrono::steady_clock::now() < until) {
                    p->processBlock(block, midi);
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                check(mock.hostFrames == uint32_t(actualFrames),
                      "Variable callback frames were replaced by prepare maximum or bridge request");
            }
            juce::AudioBuffer<float> bypassed(2, 32);
            p->processBlockBypassed(bypassed, midi);
            p->releaseResources();
        }
        check(mock.sentFrames > 10000, "Track audio was not sent");
        check(!mock.badAudio, "Track send produced invalid samples");
        check(!mock.badClaim, "A peer-list reorder changed the selected person");
        std::cout << "Processor audio and state checks passed\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
