#import <Foundation/Foundation.h>

// Preference key (inside the "YTMUltimate" defaults dictionary) for the
// "Track listening" switch. Missing means on.
extern NSString *const YTMUStatsEnabledKey;

// Turns the player's frequent time updates into listening sessions and saves
// them to YTMUStatsStore. Main thread only.
@interface YTMUStatsTracker : NSObject
+ (instancetype)sharedTracker;

// Called when a video is activated and on every playback time update.
- (void)observeVideoID:(NSString *)videoID
                 title:(NSString *)title
                artist:(NSString *)artist
              duration:(double)duration
             mediaTime:(double)mediaTime;

// Saves the current session and stops tracking it.
- (void)endCurrent;

// Forgets the current session without saving (used after clearing history).
- (void)discardCurrent;

// Re-reads the on/off preference right away.
- (void)reloadPreferences;
@end
