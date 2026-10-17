#include "BridgeClient.h"
#include "PluginHostRuntime.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>

BridgeClient::BridgeClient() = default;
BridgeClient::~BridgeClient() {
    stop();
}
void BridgeClient::start(double rate) {
    stop();
    if (!std::isfinite(rate) || rate < remsound::minimumHostRate || rate > remsound::maximumHostRate)
        return;
    hostRate.store(rate);
    hostCallbackFrames.store(0);
    audioTicks.store(0);
    sending.discard();
    receiving.discard();
    auto owner = remsound::acquireHostSendBusV1(rate);
    if (!owner || !sendEndpoint.open(rate, {&sending, [](void *context, const float *left, const float *right, size_t frames, float gain) noexcept {
        return static_cast<remsound::AudioFifo *>(context)->push(left, right, frames, gain);
    }}, std::move(owner))) return;
    exiting = false;
    log.event("plugin started at " + juce::String(rate, 0) + " Hz");
    worker = std::thread([this] { run(); });
}
void BridgeClient::stop() {
    sendEndpoint.close();
    exiting = true;
    if (worker.joinable())
        worker.join();
    connected = false;
    sending.discard();
}
juce::String BridgeClient::peerName(int slot) const {
    std::lock_guard<std::mutex> lock(peerMutex);
    return slot > 0 && size_t(slot) <= peers.size()
               ? juce::String(slot) + ": " + peers[size_t(slot - 1)].second
               : juce::String(slot) + ": no peer";
}
juce::String BridgeClient::text(const std::array<uint8_t, 4> &ip) {
    return juce::String(ip[0]) + "." + juce::String(ip[1]) + "." + juce::String(ip[2]) + "." + juce::String(ip[3]);
}
juce::String BridgeClient::selectedPeerAddress() const {
    std::lock_guard<std::mutex> lock(peerMutex);
    return selectedAddresses.isEmpty() ? juce::String() : selectedAddresses[0];
}
void BridgeClient::restorePeerAddress(const juce::String &address) {
    restorePeerAddresses(juce::StringArray(address));
}
juce::StringArray BridgeClient::selectedPeerAddresses() const {
    std::lock_guard<std::mutex> lock(peerMutex);
    return selectedAddresses;
}
void BridgeClient::restorePeerAddresses(const juce::StringArray &addresses) {
    juce::StringArray valid;
    for (auto &address : addresses) {
        in_addr ip{};
        if (inet_pton(AF_INET, address.trim().toRawUTF8(), &ip) == 1 && !valid.contains(address.trim()) && valid.size() < 32)
            valid.add(address.trim());
    }
    std::lock_guard<std::mutex> lock(peerMutex);
    selectedAddresses = valid;
}
std::vector<std::pair<juce::String, juce::String>> BridgeClient::peerRows() const {
    std::lock_guard<std::mutex> lock(peerMutex);
    std::vector<std::pair<juce::String, juce::String>> rows;
    for (auto &p : peers)
        rows.push_back({text(p.first), p.second});
    return rows;
}
bool BridgeClient::isPeerSelected(const juce::String &address) const {
    std::lock_guard<std::mutex> lock(peerMutex);
    return selectedAddresses.contains(address);
}
bool BridgeClient::togglePeer(const juce::String &address) {
    in_addr ip{};
    if (inet_pton(AF_INET, address.toRawUTF8(), &ip) != 1)
        return false;
    std::lock_guard<std::mutex> lock(peerMutex);
    if (selectedAddresses.contains(address)) {
        selectedAddresses.removeString(address);
        return false;
    }
    if (selectedAddresses.size() < 32)
        selectedAddresses.add(address);
    return selectedAddresses.contains(address);
}
void BridgeClient::run() {
#if defined(REMSOUND_TESTING)
    testWorkerStarts.fetch_add(1);
#endif
    using namespace remsound;
    const int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return;
    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, reinterpret_cast<sockaddr *>(&local), sizeof(local)) != 0) {
        close(fd);
        return;
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    sockaddr_in app{};
    app.sin_family = AF_INET;
    app.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    app.sin_port = htons(bridgePort);
    const uint32_t instance = uint32_t(juce::Random::getSystemRandom().nextInt());
    auto send = [&](Kind kind, const std::vector<uint8_t> &body = std::vector<uint8_t>{}) {
        auto d = packet(kind, instance, body);
        sendto(fd, d.data(), d.size(), 0, reinterpret_cast<sockaddr *>(&app), sizeof(app));
    };
    using Clock = std::chrono::steady_clock;
    auto now = Clock::now(), nextHello = now, nextClaim = now, lastReply = now - std::chrono::seconds(10),
         lastAudio = now;
    uint64_t lastTick = audioTicks.load();
    uint32_t ask = 0;
    bool wasReceiving = false;
    const double rate = hostRate.load(), toWire = rate / wireRate;
    const auto staleSendFrames = size_t(std::ceil(rate * 0.25));
    const auto recentSendFrames = size_t(std::ceil(rate * 0.05));
    juce::LagrangeInterpolator sendL, sendR, receiveL, receiveR;
    std::vector<float> pendingL, pendingR, receivePendingL, receivePendingR;
    // macOS worker stacks are small; allocate bounded scratch once, off the audio callback.
    std::vector<float> left(32768), right(32768), outL(32768), outR(32768);
    std::vector<uint8_t> datagram(65536);
    uint32_t lastReceivedAsk = 0;
    int previousSlot = -1;
    juce::String lastJob;
    auto nextSnapshot = now + std::chrono::seconds(1);
    while (!exiting.load()) {
        now = Clock::now();
        const auto tick = audioTicks.load(std::memory_order_acquire);
        if (tick != lastTick) {
            lastAudio = now;
            lastTick = tick;
        }
        const bool processing = now - lastAudio < std::chrono::milliseconds(500),
                   enabled = active.load() && processing;
        if (now >= nextHello) {
            std::vector<uint8_t> p;
            put32(p, uint32_t(getpid()));
            send(Kind::hello, p);
            if (processing && tick > 0) {
                auto geometry = hostGeometryBody(rate, hostCallbackFrames.load(std::memory_order_relaxed));
                if (!geometry.empty())
                    send(Kind::hostCallback, geometry);
            }
            nextHello = now + std::chrono::seconds(1);
        }
        for (int n = 0; n < 64; ++n) {
            sockaddr_in source{};
            socklen_t size = sizeof(source);
            auto length = recvfrom(fd, datagram.data(), datagram.size(), 0,
                                   reinterpret_cast<sockaddr *>(&source), &size);
            if (length < 0)
                break;
            if (source.sin_addr.s_addr != app.sin_addr.s_addr || source.sin_port != app.sin_port ||
                !valid(datagram.data(), size_t(length), instance))
                continue;
            const auto *p = datagram.data() + headerSize;
            const auto bytes = size_t(length) - headerSize;
            if (Kind(datagram[5]) == Kind::peers) {
                juce::String text = juce::String::fromUTF8(reinterpret_cast<const char *>(p), int(bytes));
                std::vector<std::pair<std::array<uint8_t, 4>, juce::String>> next;
                for (auto line : juce::StringArray::fromLines(text)) {
                    auto address = line.upToFirstOccurrenceOf("\t", false, false);
                    in_addr ip{};
                    if (inet_pton(AF_INET, address.toRawUTF8(), &ip) != 1)
                        continue;
                    std::array<uint8_t, 4> raw{};
                    std::memcpy(raw.data(), &ip.s_addr, 4);
                    next.push_back({raw, line.fromFirstOccurrenceOf("\t", false, false)});
                    if (next.size() == maxPeers)
                        break;
                }
                juce::String listed;
                for (auto &entry : next)
                    listed += (listed.isEmpty() ? "" : ", ") + entry.second;
                bool changedList = false;
                {
                    std::lock_guard<std::mutex> lock(peerMutex);
                    changedList = next != peers;
                    peers = std::move(next);
                }
                if (changedList)
                    log.event("peer list changed - now " + (listed.isEmpty() ? juce::String("nobody") : listed));
                lastReply = now;
            } else if (Kind(datagram[5]) == Kind::audio && bytes >= roundHeader && enabled &&
                       receiveEnabled.load()) {
                const uint32_t number = read32(p + 8), offset = read32(p + 12), total = read32(p + 16);
                if (total == 0 || total > maxBlockFrames * 2 || offset >= total ||
                    (bytes - roundHeader) % 8 || offset % 2 || total % 2)
                    continue;
                const size_t count = (bytes - roundHeader) / 4;
                if (offset + count > total || number + 8 < ask)
                    continue;
                if (int32_t(number - lastReceivedAsk) <= 0)
                    continue;
                // Core requests are 240 frames, fitting one datagram; never play partial replies.
                if (offset != 0 || count != total)
                    continue;
                lastReceivedAsk = number;
                const int frames = int(total / 2);
                for (int i = 0; i < frames; ++i) {
                    auto a = read32(p + roundHeader + size_t(i) * 8),
                         b = read32(p + roundHeader + size_t(i) * 8 + 4);
                    std::memcpy(&left[size_t(i)], &a, 4);
                    std::memcpy(&right[size_t(i)], &b, 4);
                }
                receivePendingL.insert(receivePendingL.end(), left.begin(), left.begin() + frames);
                receivePendingR.insert(receivePendingR.end(), right.begin(), right.begin() + frames);
                const int outputs = int(std::floor((double(receivePendingL.size()) - 8) * rate / wireRate));
                if (outputs > 0 && outputs < int(outL.size())) {
                    const int used =
                        receiveL.process(wireRate / rate, receivePendingL.data(), outL.data(), outputs);
                    receiveR.process(wireRate / rate, receivePendingR.data(), outR.data(), outputs);
                    receivePendingL.erase(receivePendingL.begin(), receivePendingL.begin() + used);
                    receivePendingR.erase(receivePendingR.begin(), receivePendingR.begin() + used);
                    receiving.push(outL.data(), outR.data(), size_t(outputs));
                }
            }
        }
        connected = now - lastReply < std::chrono::seconds(3);
        // What this track is doing, said once each time it changes, and the figures once a second (Windows PluginLog).
        const auto chosenText = allPeers.load() ? juce::String("all peers") : selectedPeerAddresses().joinIntoString(", ");
        const juce::String job = juce::String(active.load() ? "active" : "bypassed") + ", send " + (sendEnabled.load() ? "on" : "off")
            + ", receive " + (receiveEnabled.load() ? "on (" + chosenText + ")" : juce::String("off"));
        if (job != lastJob) {
            lastJob = job;
            log.event("job: " + job);
        }
        if (now >= nextSnapshot) {
            nextSnapshot = now + std::chrono::seconds(1);
            size_t known = 0;
            {
                std::lock_guard<std::mutex> lock(peerMutex);
                known = peers.size();
            }
            log.snapshot(job + "\t" + (chosenText.isEmpty() ? juce::String("-") : chosenText) + "\t"
                + (connected.load() ? "yes" : "no") + "\t" + juce::String(rate, 0) + "\t"
                + juce::String(int(hostCallbackFrames.load())) + "\t" + juce::String(int64_t(receiving.available())) + "\t"
                + juce::String(int64_t(sending.available())) + "\t" + juce::String(int64_t(known)) + "\t"
                + juce::String(int64_t(audioTicks.load())));
        }
        const bool receivingNow = enabled && receiveEnabled.load() && connected.load();
        if (!receivingNow && wasReceiving) {
            send(Kind::release);
            receiveL.reset();
            receiveR.reset();
            receivePendingL.clear();
            receivePendingR.clear();
        }
        wasReceiving = receivingNow;
        if (receivingNow && now >= nextClaim) {
            std::vector<uint8_t> body;
            put32(body, 240);
            std::vector<std::array<uint8_t, 4>> chosen;
            {
                std::lock_guard<std::mutex> lock(peerMutex);
                const int slot = peerSlot.load(), i = slot - 1;
                // The peer cursor (a host's automation, or a screen reader's parameter list) picks one peer: moving it
                // makes that peer the choice. Nothing chosen yet, it starts at the cursor's peer.
                if ((selectedAddresses.isEmpty() || (previousSlot >= 0 && slot != previousSlot)) && i >= 0 &&
                    size_t(i) < peers.size())
                    selectedAddresses = juce::StringArray(text(peers[size_t(i)].first));
                previousSlot = slot;
                if (allPeers.load()) {
                    for (auto &p : peers)
                        chosen.push_back(p.first);
                } else {
                    for (auto &address : selectedAddresses) {
                        in_addr ip{};
                        if (chosen.size() < 32 && inet_pton(AF_INET, address.toRawUTF8(), &ip) == 1) {
                            std::array<uint8_t, 4> raw{};
                            std::memcpy(raw.data(), &ip.s_addr, 4);
                            chosen.push_back(raw);
                        }
                    }
                }
            }
            body.push_back(uint8_t(chosen.size()));
            for (auto &p : chosen)
                body.insert(body.end(), p.begin(), p.end());
            put32(body, ++ask);
            send(Kind::claim, body);
            nextClaim += std::chrono::milliseconds(5);
            if (now - nextClaim > std::chrono::milliseconds(20))
                nextClaim = now;
        } else if (!receivingNow)
            nextClaim = now;
        if (enabled && sendEnabled.load() && connected.load()) {
            if (sending.available() > staleSendFrames) {
                sending.trimTo(recentSendFrames);
                pendingL.clear();
                pendingR.clear();
                sendL.reset();
                sendR.reset();
            }
            const auto count = std::min<size_t>(sending.available(), left.size());
            if (count) {
                sending.pop(left.data(), right.data(), count);
                pendingL.insert(pendingL.end(), left.begin(), left.begin() + long(count));
                pendingR.insert(pendingR.end(), right.begin(), right.begin() + long(count));
            }
            if (pendingL.size() > staleSendFrames) {
                const auto drop = pendingL.size() - recentSendFrames;
                pendingL.erase(pendingL.begin(), pendingL.begin() + long(drop));
                pendingR.erase(pendingR.begin(), pendingR.begin() + long(drop));
                sendL.reset();
                sendR.reset();
            }
            const auto required = size_t(std::ceil(toWire * 240) + 8);
            for (int blocks = 0; blocks < 64 && pendingL.size() >= required; ++blocks) {
                const int used = sendL.process(toWire, pendingL.data(), outL.data(), 240);
                sendR.process(toWire, pendingR.data(), outR.data(), 240);
                pendingL.erase(pendingL.begin(), pendingL.begin() + used);
                pendingR.erase(pendingR.begin(), pendingR.begin() + used);
                std::vector<uint8_t> body;
                body.reserve(1920);
                for (int i = 0; i < 240; ++i) {
                    uint32_t a, b;
                    std::memcpy(&a, &outL[size_t(i)], 4);
                    std::memcpy(&b, &outR[size_t(i)], 4);
                    put32(body, a);
                    put32(body, b);
                }
                send(Kind::track, body);
            }
        } else {
            sending.discard();
            pendingL.clear();
            pendingR.clear();
            sendL.reset();
            sendR.reset();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    send(Kind::goodbye);
    close(fd);
}
