// Loaded by /usr/bin/perl (an Apple-entitled process, so MediaRemote answers it) — the same trick as
// the open-source mediaremote-adapter. Perl installs these as XSUBs; the arguments perl passes are ignored.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientStringFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(int, CFDictionaryRef);
// Same call MRMediaRemoteSendCommand makes, with an app bundle ID instead of "whoever is now playing".
typedef Boolean (*SendToAppFn)(int, CFDictionaryRef, void *, CFStringRef, int, void *, void *);
typedef void (*SetElapsedFn)(double);

static void *mr;
static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static GetPIDFn getPID;
static GetClientFn getClient;
static ClientStringFn clientBundle, clientParentBundle, clientName;
static RegisterFn registerNotes;
static SendFn sendCommand;
static SendToAppFn sendToApp;
static SetElapsedFn setElapsed;

static BOOL load(void) {
    if (mr) return YES;
    mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) return NO;
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    clientName = dlsym(mr, "MRNowPlayingClientGetDisplayName");
    registerNotes = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    sendToApp = dlsym(mr, "MRMediaRemoteSendCommandToApp");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    return getInfo != NULL;
}

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSUInteger lastArtworkHash;
static dispatch_queue_t queue;

static void fetch(void) {
    getInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"type"] = @"info";
        #define COPY(key, name) { id v = info[@"kMRMediaRemoteNowPlayingInfo" key]; if (v && ![v isKindOfClass:NSData.class]) out[name] = [v isKindOfClass:NSDate.class] ? @([(NSDate *)v timeIntervalSince1970]) : v; }
        COPY(@"Title", @"title")
        COPY(@"Artist", @"artist")
        COPY(@"Album", @"album")
        COPY(@"Duration", @"duration")
        COPY(@"ElapsedTime", @"elapsed")
        COPY(@"PlaybackRate", @"rate")
        COPY(@"Timestamp", @"timestamp")
        COPY(@"IsMusicApp", @"isMusicApp")
        COPY(@"UniqueIdentifier", @"uid")
        COPY(@"ContentItemIdentifier", @"contentId")
        COPY(@"RadioStationName", @"station")
        COPY(@"Genre", @"genre")
        #undef COPY
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:NSData.class] && art.length > 0) {
            NSUInteger h = art.length ^ (art.hash << 1);
            out[@"artworkKey"] = @(h);
            if (h != lastArtworkHash) {
                out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                lastArtworkHash = h;
            }
        } else {
            lastArtworkHash = 0;
        }
        if (getPID) getPID(queue, ^(int pid) {
            out[@"pid"] = @(pid);
            void (^finish)(void) = ^{
                if (getPlaying) getPlaying(queue, ^(Boolean playing) {
                    out[@"playing"] = @(playing);
                    emit(out);
                }); else emit(out);
            };
            if (getClient && clientBundle) getClient(queue, ^(id client) {
                if (client) {
                    NSString *b = (__bridge NSString *)clientBundle(client);
                    NSString *p = clientParentBundle ? (__bridge NSString *)clientParentBundle(client) : nil;
                    NSString *n = clientName ? (__bridge NSString *)clientName(client) : nil;
                    if (b) out[@"bundle"] = b;
                    if (p) out[@"parentBundle"] = p;
                    if (n) out[@"appName"] = n;
                }
                finish();
            }); else finish();
        });
    });
}

void orbit_stream(void) {
    @autoreleasepool {
        if (!load()) { emit(@{@"type": @"error", @"message": @"MediaRemote unavailable"}); return; }
        queue = dispatch_queue_create("orbit.mediaremote", DISPATCH_QUEUE_SERIAL);
        registerNotes(queue);
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                           @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"];
        // Bursts of notifications for one change collapse into one read.
        __block BOOL pending = NO;
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
                dispatch_async(queue, ^{
                    if (pending) return;
                    pending = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), queue, ^{ pending = NO; fetch(); });
                });
            }];
        }
        emit(@{@"type": @"ready"});
        dispatch_async(queue, ^{ fetch(); });
        // Quit with Orbit: stdin closes when the parent goes away.
        dispatch_source_t eof = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
        dispatch_source_set_event_handler(eof, ^{
            char buf[64];
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n <= 0) exit(0);
            // Any line on stdin asks for a fresh read.
            fetch();
        });
        dispatch_resume(eof);
        CFRunLoopRun();
    }
}

/// One command, from ORBIT_MR_CMD (a MediaRemote command number) or ORBIT_MR_SEEK (seconds).
void orbit_send(void) {
    @autoreleasepool {
        if (!load()) exit(2);
        const char *seek = getenv("ORBIT_MR_SEEK");
        if (seek && setElapsed) { setElapsed(atof(seek)); usleep(150000); exit(0); }
        const char *cmd = getenv("ORBIT_MR_CMD");
        if (!cmd || !sendCommand) exit(2);
        const char *app = getenv("ORBIT_MR_APP");
        Boolean ok = app && sendToApp
            ? sendToApp(atoi(cmd), NULL, NULL, (__bridge CFStringRef)@(app), 0, NULL, NULL)
            : sendCommand(atoi(cmd), NULL);
        usleep(150000);
        exit(ok ? 0 : 1);
    }
}
