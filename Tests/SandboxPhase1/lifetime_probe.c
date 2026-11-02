// Disposable owned-group cleanup and accepted detached-survivor regression.
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
static void mark(const char *path) { FILE *f=fopen(path,"w"); if(f){fputs("survived",f);fclose(f);} }
static void closefds(void) { for(int i=0;i<256;i++)close(i); }
int main(int argc,char **argv) {
    if(argc<5)return 2;
    // spawn <mode> <marker> <ready-file> <denied-path>
    const char *mode=argv[2],*marker=argv[3],*ready=argv[4];
    if(!strcmp(mode,"resistant"))signal(SIGTERM,SIG_IGN);
    int ack[2];if(pipe(ack))return 3;
    pid_t child=fork();if(child<0)return 4;
    if(!child) {
        close(ack[0]);
        if(strcmp(mode,"background") && strcmp(mode,"resistant")) {
            if(!strcmp(mode,"pgroup")) {if(setpgid(0,0))_exit(5);}
            else if(setsid()<0)_exit(6);
        }
        if(!strcmp(mode,"double")) {
            pid_t last=fork();if(last<0)_exit(7);if(last)_exit(0);
        }
        write(ack[1],"r",1);close(ack[1]);
        closefds();mark(ready);
        usleep(600000);if(argc>5)mark(argv[5]);mark(marker);_exit(0);
    }
    close(ack[1]);char c;if(read(ack[0],&c,1)!=1)return 8;close(ack[0]);
    printf("ready\n");fflush(stdout);
    // Keep group identity reserved until the supervisor sends its final group signal.
    for(;;)pause();
}
