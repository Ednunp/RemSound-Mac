#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void marker(const char *path, const char *suffix, int value) {
    char target[4096];snprintf(target,sizeof(target),"%s.%s",path,suffix);
    int fd=open(target,O_WRONLY|O_CREAT|O_TRUNC,0600);
    if(fd<0) _exit(92);
    char text[32];int count=snprintf(text,sizeof(text),"%d",value);
    if(write(fd,text,(size_t)count)!=count) _exit(93);
    close(fd);
}
int main(int argc,char **argv) {
    alarm(15);
    const char *name=strrchr(argv[0],'/');name=name?name+1:argv[0];
    if(getpgrp()!=getpid() || !getenv("TAILSCALE_BE_CLI") || strcmp(getenv("TAILSCALE_BE_CLI"),"1") || getenv("HOME")) return 90;
    int funnel=argc==4 && !strcmp(argv[1],"funnel") && !strcmp(argv[2],"status") && !strcmp(argv[3],"--json");
    int node=argc==3 && !strcmp(argv[1],"status") && !strcmp(argv[2],"--json");
    int turn_on=argc==4 && !strcmp(argv[1],"funnel") && !strcmp(argv[2],"--bg") && !strcmp(argv[3],"6001");
    if(!funnel && !node && !turn_on) return 91;
    marker(argv[0],"pid",getpid());
    char receipt[48];snprintf(receipt,sizeof(receipt),"all-%d.pid",getpid());marker(argv[0],receipt,getpid());
    marker(argv[0],funnel?"status":node?"node":"funnel",getpid());
    if(!strcmp(name,"silent") || !strcmp(name,"deadline")) {signal(SIGTERM,SIG_IGN);for(;;) pause();}
    if(!strcmp(name,"inherited")) {
        pid_t child=fork();if(child<0) return 94;
        if(!child) {signal(SIGTERM,SIG_IGN);alarm(5);for(;;)pause();}
        marker(argv[0],"child",child);return 0;
    }
    if(!strcmp(name,"nonzero")) {write(2,"private diagnostic",18);return 7;}
    if(!strcmp(name,"stdout") || !strcmp(name,"stderr")) {char block[16384];memset(block,'x',sizeof(block));int fd=!strcmp(name,"stderr")?2:1;for(int i=0;i<32;i++) if(write(fd,block,sizeof(block))<0) break;return 0;}
    if(!strcmp(name,"halfclosed")) {write(1,"bad",3);close(1);usleep(100000);close(2);usleep(100000);return 0;}
    if(turn_on) {
        if(!strcmp(name,"approval-needed")) {
            fprintf(stderr,"Enable HTTPS:\nhttps://login.tailscale.com/f/serve?node=synthetic\n");fflush(stderr);
            usleep(50000);
            printf("Enable Funnel:\nhttps://login.tailscale.com/f/funnel?node=synthetic\n");fflush(stdout);
        }
        return 0;
    }
    if(funnel) printf("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"mac.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:6001\"}}}},\"AllowFunnel\":{\"mac.tail.ts.net:443\":true}}");
    else printf("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"mac.tail.ts.net.\"}}");
    return 0;
}
