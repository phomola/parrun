#import <Foundation/Foundation.h>

void terminate_tasks_and_exit(NSArray* tasks, int ret) {
    @autoreleasepool {
        __auto_type start = [NSDate date];
        for (NSTask* task in tasks) {
            [task terminate];
        }
        for (NSTask* task in tasks) {
            [task waitUntilExit];
        }
        NSLog(@"tasks terminated: %f", -[start timeIntervalSinceNow]);
    }
    exit(ret);
}

void fsCallback(ConstFSEventStreamRef stream,
                void* info,
                size_t num_events,
                void* paths,
                const FSEventStreamEventFlags flags[],
                const FSEventStreamEventId ids[]) {
    @autoreleasepool {
        NSInteger i = 0;
        for (NSString* path in (__bridge NSArray*)paths) {
            if (flags[i] & kFSEventStreamEventFlagItemInodeMetaMod) {
                __auto_type tasks = (__bridge NSMutableArray*)info;
                for (NSTask* task in tasks) {
                    if ([path isEqualToString: task.executableURL.path]) {
                        __auto_type start = [NSDate date];
                        [task terminate];
                        [task waitUntilExit];
                        NSLog(@"task terminated: %f", -[start timeIntervalSinceNow]);
                        __auto_type newTask = [[NSTask alloc] init];
                        __auto_type pipe = [NSPipe pipe];
                        newTask.arguments = task.arguments;
                        newTask.standardOutput = pipe;
                        newTask.standardError = pipe;
                        newTask.executableURL = task.executableURL;
                        newTask.environment = task.environment;
                        newTask.currentDirectoryURL = task.currentDirectoryURL;
                        NSError* error;
                        __auto_type success = [newTask launchAndReturnError: &error];
                        if (!success) {
                            NSLog(@"failed to launch task: %@", [error localizedDescription]);
                            terminate_tasks_and_exit(tasks, 1);
                        }
                        NSLog(@"task restarted");
                        tasks[i] = newTask;
                        [NSThread detachNewThreadWithBlock: ^{
                            @autoreleasepool {
                                __auto_type reader = [pipe fileHandleForReading];
                                for (;;) {
                                    @autoreleasepool {
                                        __auto_type data = [reader availableData];
                                        if (data == nil || [data length] == 0) break;
                                        NSLog(@"got: %@", [[NSString alloc] initWithData: data
                                                                                encoding: NSUTF8StringEncoding]);
                                    }
                                }
                                NSLog(@"task output closed");
                            }
                        }];
                        break;
                    }
                }
            }
            i++;
        }
    }
}

int main() {
    __auto_type tasks = [NSMutableArray array];
    @autoreleasepool {
        __auto_type args = [[NSProcessInfo processInfo] arguments];
        if ([args count] < 2) {
            NSLog(@"no config file");
            return 1;
        }
        NSError* error;
        __auto_type data = [NSData dataWithContentsOfFile: args[1]
                                                  options: 0
                                                    error: &error];
        if (data == nil) {
            NSLog(@"failed to read config: %@", [error localizedDescription]);
            return 1;
        }
        NSDictionary* config = [NSJSONSerialization JSONObjectWithData: data
                                                               options: 0
                                                                 error: &error];
        if (config == nil) {
            NSLog(@"failed to parse config: %@", [error localizedDescription]);
            return 1;
        }
        __auto_type currentDir = [[NSFileManager defaultManager] currentDirectoryPath];
        for (NSDictionary* service in config[@"services"]) {
            NSString* binary = service[@"binary"];
            __auto_type task = [[NSTask alloc] init];
            __auto_type pipe = [NSPipe pipe];
            __auto_type env = [NSMutableDictionary dictionary];
            for (NSDictionary* pair in service[@"envvars"]) {
                env[pair[@"name"]] = pair[@"value"];
            }
            task.arguments = service[@"args"];
            task.standardOutput = pipe;
            task.standardError = pipe;
            task.executableURL = [NSURL fileURLWithPath: binary];
            task.environment = env;
            __auto_type workingDir = [currentDir stringByAppendingPathComponent: service[@"workingdir"]];
            task.currentDirectoryURL = [NSURL fileURLWithPath: workingDir];
            __auto_type success = [task launchAndReturnError: &error];
            if (!success) {
                NSLog(@"failed to launch task: %@", [error localizedDescription]);
                terminate_tasks_and_exit(tasks, 1);
            }
            [tasks addObject: task];
            [NSThread detachNewThreadWithBlock: ^{
                @autoreleasepool {
                    __auto_type reader = [pipe fileHandleForReading];
                    for (;;) {
                        @autoreleasepool {
                            __auto_type data = [reader availableData];
                            if (data == nil || [data length] == 0) break;
                            NSLog(@"got: %@", [[NSString alloc] initWithData: data
                                                                    encoding: NSUTF8StringEncoding]);
                        }
                    }
                    NSLog(@"task output closed");
                }
            }];
        }
        
        __auto_type paths = [NSMutableArray array];
        for (NSTask * task in tasks) {
            [paths addObject: task.executableURL.path];
        }
        
        FSEventStreamContext ctx = { .info = (__bridge void*)tasks };
        __auto_type stream = FSEventStreamCreate(kCFAllocatorDefault,
                                                 &fsCallback,
                                                 &ctx,
                                                 (__bridge CFArrayRef)paths,
                                                 kFSEventStreamEventIdSinceNow,
                                                 1,
                                                 kFSEventStreamCreateFlagUseCFTypes|kFSEventStreamCreateFlagFileEvents);
        FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
        FSEventStreamStart(stream);
    }
    
    signal(SIGINT, SIG_IGN);
    __auto_type source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    if (source != NULL) {
        dispatch_source_set_event_handler(source, ^{
            NSLog(@"SIGINT caught");
            terminate_tasks_and_exit(tasks, 0);
        });
        dispatch_resume(source);
    }

    [[NSRunLoop currentRunLoop] run];
}

#if !__has_feature(objc_arc)
	#error ARC is required
#endif
