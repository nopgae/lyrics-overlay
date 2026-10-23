// Streams the system "Now Playing" info (what Control Center shows) as JSON lines
// on stdout, and runs transport commands read from stdin.
//
// MediaRemote answers only Apple-signed processes since macOS 15.4, so this library
// is loaded into /usr/bin/perl rather than into the app. It exits when stdin closes,
// i.e. when the app that spawned it goes away.
//
// stdout: {"title":…, "artist":…, "album":…, "duration":…, "elapsed":…, "timestamp":…,
//          "rate":…, "playing":…, "bundle":…, "app":…, "artwork":"/path" | absent}
//         or {"empty":true} when nothing is playing.
// stdin:  "toggle" | "next" | "previous" | "seek <seconds>"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import "NowPlayingHelper.h"

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetBool)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientString)(id);
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetBool getIsPlaying;
static MRGetClient getClient;
static MRClientString clientBundle, clientParent, clientName;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;

static NSString *lastArtworkID;
static NSString *lastArtworkPath;
static BOOL emitScheduled;

// MediaRemote command IDs (MRMediaRemoteCommand)
enum { kTogglePlayPause = 2, kNextTrack = 4, kPreviousTrack = 5 };

static void writeLine(NSDictionary *obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *artworkPath(NSDictionary *info) {
    NSData *data = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    // Some players reuse one artwork identifier across tracks, so key on the title too.
    NSString *ident = [NSString stringWithFormat:@"%@-%lu-%lu",
        [info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] description] ?: @"",
        (unsigned long)[info[@"kMRMediaRemoteNowPlayingInfoTitle"] hash], (unsigned long)data.length];
    if ([ident isEqualToString:lastArtworkID]) return lastArtworkPath;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"lyrics-overlay-nowplaying-artwork"];
    if (![data writeToFile:path atomically:YES]) return nil;
    lastArtworkID = ident;
    lastArtworkPath = [path stringByAppendingFormat:@"#%@", ident];  // fragment busts the app's cache
    return lastArtworkPath;
}

static void emit(void) {
    emitScheduled = NO;
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        if (info.count == 0 || !info[@"kMRMediaRemoteNowPlayingInfoTitle"]) {
            writeLine(@{@"empty": @YES});
            return;
        }
        getIsPlaying(q, ^(BOOL playing) {
            getClient(q, ^(id client) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = @([ts isKindOfClass:[NSDate class]] ? ts.timeIntervalSince1970
                                                                         : NSDate.date.timeIntervalSince1970);
                out[@"playing"] = @(playing);
                if (client) {
                    // Web players report WebKit's GPU process; the parent is the real app.
                    out[@"bundle"] = clientParent(client) ?: clientBundle(client) ?: @"";
                    out[@"app"] = clientName(client) ?: @"";
                }
                NSString *art = artworkPath(info);
                if (art) out[@"artwork"] = art;
                writeLine(out);
            });
        });
    });
}

/// MediaRemote fires several notifications per change; coalesce them.
static void scheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *cmd = [[NSString stringWithUTF8String:buf]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([cmd isEqualToString:@"toggle"]) sendCommand(kTogglePlayPause, nil);
                else if ([cmd isEqualToString:@"next"]) sendCommand(kNextTrack, nil);
                else if ([cmd isEqualToString:@"previous"]) sendCommand(kPreviousTrack, nil);
                else if ([cmd hasPrefix:@"seek "]) setElapsed([[cmd substringFromIndex:5] doubleValue]);
                else if ([cmd isEqualToString:@"refresh"]) scheduleEmit();
            });
        }
        exit(0);  // stdin closed: the app is gone
    });
}

void np_run(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetBool)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (MRGetClient)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (MRClientString)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = (MRClientString)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    clientName = (MRClientString)dlsym(mr, "MRNowPlayingClientGetDisplayName");
    sendCommand = (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegister reg = (MRRegister)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getClient || !clientBundle || !clientParent || !clientName
        || !sendCommand || !setElapsed || !reg) {
        writeLine(@{@"error": @"MediaRemote symbols missing"});
        exit(1);
    }

    reg(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *n) { scheduleEmit(); }];
    }
    readCommands();
    scheduleEmit();
    CFRunLoopRun();
}
