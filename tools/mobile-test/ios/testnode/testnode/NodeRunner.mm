//
//  NodeRunner.m
//  testnode
//

#include "NodeRunner.hpp"
#include <NodeMobile/NodeMobile.h>
#include <string>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Per-launch verdict file in the app's Documents dir (host-readable via
// `simctl get_app_container`). The proxy reads the test's real exit code from
// this durable file instead of scraping the lossy `simctl --console` stream
// (which drops output intermittently on CI). Path is built from the per-launch
// token (set by main.m from --run-token via NODE_MOBILE_RUN_TOKEN); an empty
// token (e.g. a spawned child that never got --run-token) writes nothing.
static char g_result_file[1024] = {0};
static bool g_result_written = false;
static void write_result(const char* verdict) {
    if (g_result_file[0] == '\0') return;
    FILE* f = fopen(g_result_file, "w");
    if (f) { fputs(verdict, f); fclose(f); g_result_written = true; }
}
static void NodeRunnerAtExitHook(void) {
    // node_start did not return (crash, abort, or an explicit process.exit()
    // which routes through node::Exit -> libc exit() and never unwinds to us).
    // Record FAIL conservatively: a real exit code is unavailable here, and for
    // the curated gate this is the safe verdict — no curated test calls
    // process.exit(), so reaching this path means an abnormal termination.
    // (Option D's SpinEventLoop returns the true code and removes this caveat.)
    if (!g_result_written) write_result("FAIL\n");
}

@implementation NodeRunner

+ (void) CopyTestDir:(NSString*)srcTestsPath:(NSString*)dstTestsPath
{
    BOOL isDir;
    if ([[NSFileManager defaultManager] fileExistsAtPath:dstTestsPath isDirectory:&isDir] && isDir) {
        [[NSFileManager defaultManager] removeItemAtPath:dstTestsPath error:nil];
    }
    
    NSLog(@"Copying test files to documents...");
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:srcTestsPath toPath:dstTestsPath error:&copyError]) {
        NSLog(@"Error copying files: %@", [copyError localizedDescription]);
        exit(1);
    }
}

//node's libUV requires all arguments being on contiguous memory.
+ (int) startEngineWithArguments:(NSArray*)arguments
{
    //Set the builtin_modules path to NODE_PATH

    int c_arguments_size=0;
    
    //Compute byte size need for all arguments in contiguous memory.
    for (id argElement in arguments)
    {
        c_arguments_size+=strlen([argElement UTF8String]);
        c_arguments_size++; // for '\0'
    }
    
    //Stores arguments in contiguous memory.
    char* args_buffer=(char*)calloc(c_arguments_size, sizeof(char));
    
    //argv to pass into node.
    char* argv[[arguments count]];
    
    //To iterate through the expected start position of each argument in args_buffer.
    char* current_args_position=args_buffer;
    
    //Argc
    int argument_count=0;
    
    //Populate the args_buffer and argv.
    for (id argElement in arguments)
    {
        const char* current_argument=[argElement UTF8String];
        
        //Copy current argument to its expected position in args_buffer
        strncpy(current_args_position, current_argument, strlen(current_argument));
        
        //Save current argument start position in argv and increment argc.
        argv[argument_count]=current_args_position;
        argument_count++;
        
        //Increment to the next argument's expected position.
        current_args_position+=strlen(current_args_position)+1;
    }
    //Build the per-launch verdict file path (<Documents>/result-<token>.txt) from
    //the token set by main.m, before starting node, so the atexit fallback can
    //write even if node aborts.
    const char* tok = getenv("NODE_MOBILE_RUN_TOKEN");
    if (tok && tok[0]) {
        NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString* rf = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"result-%s.txt", tok]];
        strncpy(g_result_file, [rf UTF8String], sizeof(g_result_file) - 1);
        atexit(NodeRunnerAtExitHook);
    }

    //Native-addon gate: point NODE_MOBILE_ADDON at the .node the harness copied
    //into Documents (test-napi-addon.js dlopens it). Harmless when absent.
    {
        NSString* d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        setenv("NODE_MOBILE_ADDON", [[d stringByAppendingPathComponent:@"crcnative.node"] UTF8String], 1);
    }

    //Start node; its return is the real exit code. Write it to the verdict file.
    int code = node_start(argument_count, argv);
    write_result(code == 0 ? "PASS\n" : "FAIL\n");
    return code;
}

@end
