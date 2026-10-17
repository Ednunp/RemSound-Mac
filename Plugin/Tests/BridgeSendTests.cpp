#include "BridgeClient.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <sys/socket.h>
#include <unistd.h>

using namespace remsound;
static int cases=0,assertions=0,failures=0;
static void check(bool result,const char *message){++assertions;if(!result){++failures;std::cerr<<"FAIL "<<message<<'\n';}}
template<class F>static void run(const char *name,F body){++cases;body();std::cout<<"CASE "<<name<<'\n';}
struct Mock {
    int fd=-1;std::thread worker;std::atomic<bool> exit{false};std::atomic<size_t> samples{0},packets{0},goodbyes{0};
    Mock(){fd=socket(AF_INET,SOCK_DGRAM,0);sockaddr_in local{};local.sin_family=AF_INET;local.sin_addr.s_addr=htonl(INADDR_LOOPBACK);local.sin_port=0;
        if(fd<0||bind(fd,reinterpret_cast<sockaddr*>(&local),sizeof(local))!=0)throw std::runtime_error("owned mock bind failed");
        socklen_t n=sizeof(local);if(getsockname(fd,reinterpret_cast<sockaddr*>(&local),&n)!=0)throw std::runtime_error("owned mock port failed");
        bridgePort=ntohs(local.sin_port);check(bridgePort!=0&&bridgePort!=47831,"no normal bridge port");fcntl(fd,F_SETFL,O_NONBLOCK);worker=std::thread([this]{loop();});}
    ~Mock(){exit=true;if(worker.joinable())worker.join();if(fd>=0)close(fd);}
    void loop(){std::array<uint8_t,65536> bytes{};while(!exit){sockaddr_in source{};socklen_t size=sizeof(source);auto n=recvfrom(fd,bytes.data(),bytes.size(),0,reinterpret_cast<sockaddr*>(&source),&size);
        if(n<0){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
        if(n<headerSize||source.sin_addr.s_addr!=htonl(INADDR_LOOPBACK))continue;auto id=read32(bytes.data()+8);if(!valid(bytes.data(),size_t(n),id))continue;
        if(Kind(bytes[5])==Kind::hello){auto reply=packet(Kind::peers,id);sendto(fd,reply.data(),reply.size(),0,reinterpret_cast<sockaddr*>(&source),size);}
        if(Kind(bytes[5])==Kind::track){++packets;samples+=size_t(n-headerSize)/sizeof(float);}
        if(Kind(bytes[5])==Kind::goodbye)++goodbyes;
    }}
};
static void connect(BridgeClient &client){for(int i=0;i<1500&&!client.connected;++i){client.audioTicks.fetch_add(1);std::this_thread::sleep_for(std::chrono::milliseconds(1));}check(client.connected,"owned bridge connected");}
static void feed(BridgeClient &client){std::array<float,480> l{},r{};l.fill(0.25f);r.fill(-0.25f);client.active=true;client.sendEnabled=true;for(int i=0;i<12;++i){client.audioTicks.fetch_add(1);auto value=client.submitTrack(true,l.data(),r.data(),l.size());check(value.admitted&&value.stored==1,"actual memory admission");std::this_thread::sleep_for(std::chrono::milliseconds(2));}}
int main(){
 run("actual bridge endpoint feeds native owned worker",[]{Mock mock;BridgeClient client;client.start(48000);connect(client);check(client.trackSendingReady(),"actual source ready");feed(client);client.stop();check(mock.packets>0&&mock.samples>0,"actual track wire produced");check(!client.trackSendingReady()&&!client.submitTrack(true).admitted,"stop fences future source");check(client.sending.available()==0,"retired local FIFO empty; no remote delivery claim");});
 run("restart owns fresh finite source visit",[]{Mock mock;BridgeClient client;for(double rate:{44100.,96000.,48000.}){client.start(rate);connect(client);feed(client);client.stop();check(!client.trackSendingReady(),"rate visit retired");}check(mock.packets>0,"restart produced only owned traffic");});
 run("same-host equal-rate clients use one production bus",[]{Mock mock;BridgeClient a,b;a.start(48000);b.start(48000);connect(a);connect(b);check(a.trackSendingReady()&&b.trackSendingReady(),"both actual visits ready");a.active=b.active=true;a.sendEnabled=b.sendEnabled=true;a.submitTrack(true);b.submitTrack(true);std::array<float,480> l{},r{};l.fill(0.25f);r.fill(-0.25f);for(int i=0;i<12;++i){a.audioTicks.fetch_add(1);b.audioTicks.fetch_add(1);check(a.submitTrack(true,l.data(),r.data(),l.size()).stored==0,"first contributor waits");check(b.submitTrack(true,l.data(),r.data(),l.size()).stored==1,"second contribution flushes actual host leader");std::this_thread::sleep_for(std::chrono::milliseconds(2));}a.stop();feed(b);b.stop();check(mock.packets>0&&mock.samples>0,"shared then survivor traffic crossed owned link");});
 run("invalid source rates refuse before worker factory",[]{Mock mock;BridgeClient client;for(double rate:{0.,-1.,7999.,768001.,std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::infinity()}){client.start(rate);client.stop();check(client.testWorkerStarts==0,"invalid geometry creates no worker/socket");check(!client.trackSendingReady()&&client.sending.available()==0,"invalid source stays retired");}});
 run("invalid replacement retires prior visit without fallback",[]{Mock mock;BridgeClient client;client.start(48000);connect(client);feed(client);auto started=client.testWorkerStarts.load();check(started==1,"one valid visit");client.start(0);check(!client.trackSendingReady(),"invalid replacement revokes old source");client.stop();check(client.testWorkerStarts==started,"old joined; no new native visit");check(client.sending.available()==0&&!client.submitTrack(true).admitted,"old source cannot replay");});
 run("exact supported clock boundaries retain native visits",[]{Mock mock;BridgeClient client;unsigned expected=0;for(double rate:{minimumHostRate,maximumHostRate}){client.start(rate);connect(client);check(client.testWorkerStarts==++expected&&client.trackSendingReady(),"boundary rate admitted exactly");client.stop();check(!client.trackSendingReady(),"boundary visit retired");}});
 std::cout<<"RESULT cases="<<cases<<" assertions="<<assertions<<" failures="<<failures<<'\n';return failures?1:0;
}
