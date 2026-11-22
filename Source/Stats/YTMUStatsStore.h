#import <Foundation/Foundation.h>

// One listening session of one song. The tracker keeps a mutable one for the
// song that is playing and hands copies to the store, so the store never sees
// an object that is still being changed on the main thread.
@interface YTMUStatsListen : NSObject <NSCopying>
@property (nonatomic, copy) NSString *session;   // unique id of this listen (UUID)
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, assign) NSTimeInterval startedAt; // seconds since 1970
@property (nonatomic, assign) double listened;          // seconds actually heard
@property (nonatomic, assign) double duration;          // song length in seconds
@property (nonatomic, assign) BOOL counted;             // passed the "counts as a play" threshold
@end

// Summary keys returned by -loadStatsSince:limit:completion:
extern NSString *const YTMUStatsSecondsKey;   // NSNumber (double), total seconds listened
extern NSString *const YTMUStatsPlaysKey;     // NSNumber, plays that counted
extern NSString *const YTMUStatsSongsKey;     // NSNumber, different songs played
extern NSString *const YTMUStatsArtistsKey;   // NSNumber, different artists played

// Row keys for top songs / top artists (plus YTMUStatsPlaysKey and YTMUStatsSecondsKey)
extern NSString *const YTMUStatsVideoIDKey;
extern NSString *const YTMUStatsTitleKey;
extern NSString *const YTMUStatsArtistKey;

typedef void (^YTMUStatsLoadCompletion)(NSDictionary *summary, NSArray<NSDictionary *> *topSongs, NSArray<NSDictionary *> *topArtists);

// SQLite-backed listening history, stored in
// Library/Application Support/YTMusicUltimate/ListeningStats.sqlite.
// Every call runs on a private serial queue; completion blocks run on the main queue.
@interface YTMUStatsStore : NSObject
+ (instancetype)sharedStore;

// Inserts the listen, or updates it if a listen with the same session was saved before.
- (void)saveListen:(YTMUStatsListen *)listen;

// since = 0 means all time.
- (void)loadStatsSince:(NSTimeInterval)since limit:(NSInteger)limit completion:(YTMUStatsLoadCompletion)completion;

- (void)clearAllWithCompletion:(void (^)(void))completion;

// Writes the whole history to a CSV file in the temporary directory. url is nil on failure.
- (void)exportCSVWithCompletion:(void (^)(NSURL *url))completion;
@end
