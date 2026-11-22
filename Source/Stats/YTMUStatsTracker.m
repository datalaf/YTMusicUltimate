#import "YTMUStatsTracker.h"
#import "YTMUStatsStore.h"
#import <UIKit/UIKit.h>

NSString *const YTMUStatsEnabledKey = @"listeningStats";

// A song counts as a play after this many seconds, or after half of it for songs shorter than a minute.
static const double kCountThreshold = 30.0;
// Time updates further apart than this are seeks, not listening.
static const double kMaxTickGap = 3.0;
// While a song plays, save progress every this many listened seconds.
static const double kSaveInterval = 15.0;
// Listens shorter than this are not saved at all.
static const double kMinSavedListen = 1.0;
// How long the cached on/off preference is trusted.
static const NSTimeInterval kPrefsCacheTime = 5.0;

static NSString *YTMUCleanArtist(NSString *artist) {
    if (artist.length == 0) return nil;
    // Auto-generated YouTube Music channels are called "Artist - Topic".
    NSString *suffix = @" - Topic";
    if ([artist hasSuffix:suffix] && artist.length > suffix.length) {
        artist = [artist substringToIndex:artist.length - suffix.length];
    }
    return [artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@interface YTMUStatsTracker ()
@property (nonatomic, strong) YTMUStatsListen *current;
@property (nonatomic, assign) double lastMediaTime;
@property (nonatomic, assign) double lastSavedListened;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSTimeInterval prefsReadAt;
@end

@implementation YTMUStatsTracker

+ (instancetype)sharedTracker {
    static YTMUStatsTracker *tracker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracker = [[YTMUStatsTracker alloc] init];
    });
    return tracker;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(saveCurrent) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(saveCurrent) name:UIApplicationWillTerminateNotification object:nil];
        [self reloadPreferences];
    }
    return self;
}

#pragma mark - Preferences

- (void)reloadPreferences {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    id statsPref = prefs[YTMUStatsEnabledKey];
    self.enabled = [prefs[@"YTMUltimateIsEnabled"] boolValue] && (statsPref == nil || [statsPref boolValue]);
    self.prefsReadAt = [NSDate timeIntervalSinceReferenceDate];
}

- (BOOL)isEnabled {
    if ([NSDate timeIntervalSinceReferenceDate] - self.prefsReadAt > kPrefsCacheTime) {
        [self reloadPreferences];
    }
    return self.enabled;
}

#pragma mark - Tracking

- (void)observeVideoID:(NSString *)videoID title:(NSString *)title artist:(NSString *)artist duration:(double)duration mediaTime:(double)mediaTime {
    if (![self isEnabled]) {
        [self endCurrent];
        return;
    }
    if (videoID.length == 0) return;

    YTMUStatsListen *listen = self.current;
    BOOL newSong = listen == nil || ![listen.videoID isEqualToString:videoID];
    // Same song again (repeat one, or replayed from the start) after the previous run already counted.
    BOOL restarted = !newSong && listen.counted && mediaTime < 3.0 && self.lastMediaTime - mediaTime > 10.0;

    if (newSong || restarted) {
        [self endCurrent];
        [self beginVideoID:videoID title:title artist:artist duration:duration mediaTime:mediaTime];
        return;
    }

    // Metadata may arrive a little after the video starts, so keep filling it in.
    if (title.length > 0) listen.title = title;
    NSString *cleanArtist = YTMUCleanArtist(artist);
    if (cleanArtist.length > 0) listen.artist = cleanArtist;
    if (duration > listen.duration) listen.duration = duration;

    double delta = mediaTime - self.lastMediaTime;
    self.lastMediaTime = mediaTime;
    if (delta <= 0 || delta > kMaxTickGap) return; // paused, duplicate update, or a seek

    listen.listened += delta;

    BOOL justCounted = NO;
    if (!listen.counted && listen.listened >= [self thresholdForDuration:listen.duration]) {
        listen.counted = YES;
        justCounted = YES;
    }

    if (justCounted || listen.listened - self.lastSavedListened >= kSaveInterval) {
        [self saveCurrent];
    }
}

- (void)beginVideoID:(NSString *)videoID title:(NSString *)title artist:(NSString *)artist duration:(double)duration mediaTime:(double)mediaTime {
    YTMUStatsListen *listen = [[YTMUStatsListen alloc] init];
    listen.session = [NSUUID UUID].UUIDString;
    listen.videoID = videoID;
    listen.title = title.length > 0 ? title : nil;
    listen.artist = YTMUCleanArtist(artist);
    listen.duration = MAX(duration, 0);
    listen.startedAt = [[NSDate date] timeIntervalSince1970];

    self.current = listen;
    self.lastMediaTime = mediaTime;
    self.lastSavedListened = 0;
}

- (double)thresholdForDuration:(double)duration {
    if (duration > 0 && duration < kCountThreshold * 2) {
        return duration / 2.0;
    }
    return kCountThreshold;
}

- (void)saveCurrent {
    YTMUStatsListen *listen = self.current;
    if (!listen || listen.listened < kMinSavedListen) return;

    [[YTMUStatsStore sharedStore] saveListen:listen];
    self.lastSavedListened = listen.listened;
}

- (void)endCurrent {
    [self saveCurrent];
    self.current = nil;
}

- (void)discardCurrent {
    self.current = nil;
}

@end
