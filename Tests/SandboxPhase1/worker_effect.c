#include <stdio.h>
#include <stdlib.h>
// Synthetic agent-callable native code loaded by the worker, never by Milk.
int effect(const char *path) {
    if (getenv("MILK_PI_LOCAL_KEY")) return 7;
    FILE *f=fopen(path,"w"); if(!f) return 1;
    fputs("native-effect",f); fclose(f); return 0;
}
