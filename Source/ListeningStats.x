#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "Headers/YTPlayerViewController.h"
#import "Stats/YTMUStatsTracker.h"

// YTIVideoDetails is a protobuf message; recent versions expose the video id,
// which lets us make sure the title belongs to the video that is playing.
@protocol YTMUStatsVideoIdentifiable
- (NSString *)videoId;
@end

static NSString *YTMUStatsString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// Reads what is playing from the player and hands it to the tracker.
// Every property is checked with respondsToSelector: so a YouTube Music update
// that renames something only stops the stats instead of crashing the app.
static void YTMUStatsObservePlayer(YTPlayerViewController *player) {
    NSString *videoID = nil;
    NSString *title = nil;
    NSString *artist = nil;
    double duration = 0;
    double mediaTime = 0;

    @try {
        if ([player respondsToSelector:@selector(currentVideoID)]) videoID = YTMUStatsString([player currentVideoID]);
        if (videoID.length == 0) return;

        if ([player respondsToSelector:@selector(currentVideoMediaTime)]) mediaTime = [player currentVideoMediaTime];
        if ([player respondsToSelector:@selector(currentVideoTotalMediaTime)]) duration = player.currentVideoTotalMediaTime;

        YTPlayerResponse *response = [player respondsToSelector:@selector(playerResponse)] ? player.playerResponse : nil;
        YTIPlayerResponse *playerData = [response respondsToSelector:@selector(playerData)] ? response.playerData : nil;
        YTIVideoDetails *details = [playerData respondsToSelector:@selector(videoDetails)] ? playerData.videoDetails : nil;

        BOOL detailsMatch = YES;
        if ([details respondsToSelector:@selector(videoId)]) {
            NSString *detailsID = YTMUStatsString([(id<YTMUStatsVideoIdentifiable>)details videoId]);
            detailsMatch = detailsID.length == 0 || [detailsID isEqualToString:videoID];
        }

        if (detailsMatch) {
            if ([details respondsToSelector:@selector(title)]) title = YTMUStatsString(details.title);
            if ([details respondsToSelector:@selector(author)]) artist = YTMUStatsString(details.author);
        }
    } @catch (NSException *exception) {
        return;
    }

    if (isnan(mediaTime) || isnan(duration)) return;

    void (^observe)(void) = ^{
        [[YTMUStatsTracker sharedTracker] observeVideoID:videoID title:title artist:artist duration:duration mediaTime:mediaTime];
    };

    if ([NSThread isMainThread]) {
        observe();
    } else {
        dispatch_async(dispatch_get_main_queue(), observe);
    }
}

%hook YTPlayerViewController

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    YTMUStatsObservePlayer(self);
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    YTMUStatsObservePlayer(self);
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    YTMUStatsObservePlayer(self);
}

%end

%ctor {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    if (prefs[YTMUStatsEnabledKey] == nil) {
        prefs[YTMUStatsEnabledKey] = @YES;
        [[NSUserDefaults standardUserDefaults] setObject:prefs forKey:@"YTMUltimate"];
    }

    %init;
}
