// Disposable native boundary probe; never linked into Milk.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <dlfcn.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "env")) { puts(getenv("MILK_PI_LOCAL_KEY") ? "present" : "absent"); return 0; }
    if (!strcmp(argv[1], "read") || !strcmp(argv[1], "write")) {
        FILE *f = fopen(argv[2], !strcmp(argv[1], "read") ? "r" : "w");
        if (!f) { printf("denied:%d\n", errno); return 1; }
        if (!strcmp(argv[1], "write")) fputs("probe", f);
        fclose(f); return 0;
    }
    if (!strcmp(argv[1], "fork")) {
        pid_t pid=fork();
        if (pid < 0) { printf("denied:%d\n",errno); return 1; }
        if (!pid) _exit(0);
        waitpid(pid,NULL,0); puts("forked"); return 0;
    }
    if (!strcmp(argv[1], "plugin")) {
        void *h=dlopen(argv[2], RTLD_NOW); if (!h) return 3;
        int (*effect)(const char *)=dlsym(h,"effect"); if (!effect) return 4;
        int result=effect(argv[3]); dlclose(h); return result;
    }
    if (!strcmp(argv[1], "detach")) {
        pid_t pid=fork(); if(pid<0) return 3;
        if (!pid) {
            if (setsid()<0) _exit(4);
            freopen("/dev/null","w",stdout); freopen("/dev/null","w",stderr);
            usleep(500000);
            FILE *f=fopen(argv[2],"w"); if(f) { fputs("survived",f); fclose(f); }
            _exit(0);
        }
        // Child is deliberately detached; test demonstrates group lifetime limitation.
        puts("detached"); return 0;
    }
    return 2;
}
