#include "SharedHostModuleAPI.h"
#include "BridgeProtocol.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <spawn.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <thread>
#include <mutex>
#include <map>
#include <set>
#include <iostream>
extern char **environ;
using namespace remsound;
static int cases=0, assertions=0, failures=0;
static size_t runtimeImages(){size_t count=0;for(uint32_t i=0;i<_dyld_image_count();++i){auto p=_dyld_get_image_name(i);if(p&&std::string(p).find("/libRemSoundPluginHost-v1.dylib")!=std::string::npos)++count;}return count;}
static void check(bool ok,const char *why){++assertions;if(!ok){++failures;std::cerr<<"FAIL "<<why<<'\n';}}
template<class F>static void run(const char *name,F f){++cases;f();std::cout<<"CASE "<<name<<'\n';}
struct Module {
 void *image=nullptr; const SharedHostModuleAPI *api=nullptr;
 explicit Module(const char *path){image=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(!image){std::cerr<<dlerror()<<'\n';return;}auto entry=reinterpret_cast<SharedHostModuleEntry>(dlsym(image,"remsoundSharedHostTestAPI"));if(entry)api=entry();}
 ~Module(){if(image)dlclose(image);}
};
struct Mock {
 int fd=-1,port=0;std::thread worker;std::atomic<bool> done{false};std::mutex gate;std::map<uint32_t,size_t> trackFrames;std::set<uint32_t> mixed,quarter;size_t invalid=0;
 Mock(){fd=socket(AF_INET,SOCK_DGRAM,0);sockaddr_in local{};local.sin_family=AF_INET;local.sin_addr.s_addr=htonl(INADDR_LOOPBACK);if(fd<0||bind(fd,reinterpret_cast<sockaddr*>(&local),sizeof(local))!=0)throw std::runtime_error("owned mock bind");socklen_t n=sizeof(local);if(getsockname(fd,reinterpret_cast<sockaddr*>(&local),&n)!=0)throw std::runtime_error("owned mock port");port=ntohs(local.sin_port);if(!port||port==47831)throw std::runtime_error("normal port refused");fcntl(fd,F_SETFL,O_NONBLOCK);worker=std::thread([this]{loop();});}
 ~Mock(){done=true;if(worker.joinable())worker.join();close(fd);}
 void clear(){std::lock_guard<std::mutex> lock(gate);trackFrames.clear();mixed.clear();quarter.clear();invalid=0;}
 void loop(){std::array<uint8_t,65536> buf{};while(!done){sockaddr_in src{};socklen_t size=sizeof(src);auto n=recvfrom(fd,buf.data(),buf.size(),0,reinterpret_cast<sockaddr*>(&src),&size);if(n<0){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}if(n<headerSize||src.sin_addr.s_addr!=htonl(INADDR_LOOPBACK))continue;auto id=read32(buf.data()+8);if(!valid(buf.data(),size_t(n),id))continue;if(Kind(buf[5])==Kind::hello){auto reply=packet(Kind::peers,id);sendto(fd,reply.data(),reply.size(),0,reinterpret_cast<sockaddr*>(&src),size);}if(Kind(buf[5])!=Kind::track)continue;std::lock_guard<std::mutex> lock(gate);trackFrames[id]+=size_t(n-headerSize)/8;for(size_t i=headerSize;i+7<size_t(n);i+=8){auto bits=read32(buf.data()+i);float l=0;std::memcpy(&l,&bits,4);bits=read32(buf.data()+i+4);float r=0;std::memcpy(&r,&bits,4);if(!std::isfinite(l)||!std::isfinite(r)||std::abs(l+r)>0.0001f)++invalid;if(std::abs(l-0.375f)<0.0001f)mixed.insert(id);if(std::abs(l-0.25f)<0.0001f)quarter.insert(id);}}}
};
static bool connect(const SharedHostModuleAPI &a,void *p){for(int i=0;i<2000&&!a.connected(p);++i)std::this_thread::sleep_for(std::chrono::milliseconds(1));return a.connected(p);}
static void rounds(const SharedHostModuleAPI &a,void *one,const SharedHostModuleAPI *b=nullptr,void *two=nullptr){for(int i=0;i<32;++i){a.feed(one,0.125f,480);if(b)b->feed(two,0.25f,480);std::this_thread::sleep_for(std::chrono::milliseconds(3));}std::this_thread::sleep_for(std::chrono::milliseconds(30));}
int main(int argc,char **argv){
 if(argc==4&&std::string(argv[1])=="--child"){Module m(argv[2]);if(!m.api)return 2;void *p=m.api->create(96000,std::stoi(argv[3]));bool ok=m.api->ready(p)&&connect(*m.api,p);if(ok)rounds(*m.api,p);m.api->stop(p);m.api->destroy(p);return ok?0:1;}
 if(argc!=3)return 2;Module a(argv[1]),b(argv[2]);if(!a.api||!b.api||a.image==b.image||a.api==b.api)return 2;Mock mock;
 run("actual Bridge factory shares one aligned host stream across modules",[&]{void *one=a.api->create(48000,mock.port),*two=b.api->create(48000,mock.port);check(runtimeImages()==1,"staged dependencies resolve to one native image");check(a.api->ready(one)&&b.api->ready(two),"both production source visits ready");check(connect(*a.api,one)&&connect(*b.api,two),"both genuine bridge workers connected");a.api->feed(one,0,0);b.api->feed(two,0,0);mock.clear();rounds(*a.api,one,b.api,two);a.api->stop(one);b.api->stop(two);{std::lock_guard<std::mutex> lock(mock.gate);check(mock.trackFrames.size()==1,"only one leader carries summed host stream");check(mock.mixed.size()==1&&mock.invalid==0,"actual wire has golden summed stereo, not concatenation");}a.api->destroy(one);b.api->destroy(two);});
 run("incompatible rate refuses until actual final release",[&]{void *one=a.api->create(48000,mock.port),*wrong=b.api->create(96000,mock.port);check(a.api->ready(one),"first rate ready");check(!b.api->ready(wrong),"no incompatible clock joins or private fallback");b.api->destroy(wrong);a.api->stop(one);a.api->destroy(one);void *fresh=b.api->create(96000,mock.port);check(b.api->ready(fresh)&&connect(*b.api,fresh),"last release allows genuine new host rate");b.api->stop(fresh);b.api->destroy(fresh);});
 run("same library in second owned host process is isolated",[&]{void *one=a.api->create(48000,mock.port);check(a.api->ready(one)&&connect(*a.api,one),"parent live48000");std::string port=std::to_string(mock.port);char *args[]={argv[0],const_cast<char*>("--child"),argv[1],port.data(),nullptr};pid_t child=-1;int code=posix_spawn(&child,argv[0],nullptr,nullptr,args,environ);check(code==0&&child>0,"exact owned child spawned");int status=0;if(code==0){check(waitpid(child,&status,0)==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0,"second host independently admits96000 and retires");}check(a.api->ready(one),"child did not replace parent owner");a.api->stop(one);a.api->destroy(one);});
 run("leader module retires and unloads while survivor continues",[&]{void *one=a.api->create(48000,mock.port),*two=b.api->create(48000,mock.port);check(connect(*a.api,one)&&connect(*b.api,two),"both visits connected before unload");a.api->feed(one,0,0);b.api->feed(two,0,0);rounds(*a.api,one,b.api,two);a.api->stop(one);a.api->destroy(one);check(dlclose(a.image)==0,"retired actual module handle closes");a.image=nullptr;a.api=nullptr;mock.clear();for(int i=0;i<24;++i){b.api->feed(two,0.25f,480);std::this_thread::sleep_for(std::chrono::milliseconds(3));}b.api->stop(two);{std::lock_guard<std::mutex> lock(mock.gate);check(mock.trackFrames.size()==1&&mock.quarter.size()==1&&mock.invalid==0,"survivor actual wire after former module unload");}b.api->destroy(two);Module reload(argv[1]);check(reload.api!=nullptr,"former module can reopen");if(reload.api){void *fresh=reload.api->create(44100,mock.port);check(reload.api->ready(fresh)&&connect(*reload.api,fresh),"full release permits new rate after reopen");reload.api->stop(fresh);reload.api->destroy(fresh);}});
 std::cout<<"RESULT cases="<<cases<<" assertions="<<assertions<<" failures="<<failures<<'\n';return failures?1:0;
}
