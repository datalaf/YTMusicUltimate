#import "YTMUStatsStore.h"
#import <sqlite3.h>

NSString *const YTMUStatsSecondsKey = @"seconds";
NSString *const YTMUStatsPlaysKey = @"plays";
NSString *const YTMUStatsSongsKey = @"songs";
NSString *const YTMUStatsArtistsKey = @"artists";
NSString *const YTMUStatsVideoIDKey = @"videoID";
NSString *const YTMUStatsTitleKey = @"title";
NSString *const YTMUStatsArtistKey = @"artist";

@implementation YTMUStatsListen

- (id)copyWithZone:(NSZone *)zone {
    YTMUStatsListen *copy = [[YTMUStatsListen allocWithZone:zone] init];
    copy.session = self.session;
    copy.videoID = self.videoID;
    copy.title = self.title;
    copy.artist = self.artist;
    copy.startedAt = self.startedAt;
    copy.listened = self.listened;
    copy.duration = self.duration;
    copy.counted = self.counted;
    return copy;
}

@end

#pragma mark - SQLite helpers

static void YTMUBindText(sqlite3_stmt *stmt, int index, NSString *value) {
    if (value.length > 0) {
        sqlite3_bind_text(stmt, index, value.UTF8String, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(stmt, index);
    }
}

static NSString *YTMUColumnText(sqlite3_stmt *stmt, int index) {
    const unsigned char *text = sqlite3_column_text(stmt, index);
    if (!text) return @"";
    return [NSString stringWithUTF8String:(const char *)text] ?: @"";
}

static NSString *YTMUCSVField(NSString *value) {
    if (!value) return @"";
    NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:@",\"\r\n"];
    if ([value rangeOfCharacterFromSet:special].location == NSNotFound) return value;
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

@implementation YTMUStatsStore {
    dispatch_queue_t _queue;
    sqlite3 *_db;
}

+ (instancetype)sharedStore {
    static YTMUStatsStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[YTMUStatsStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.ytmusicultimate.listeningstats", DISPATCH_QUEUE_SERIAL);
        dispatch_async(_queue, ^{
            [self openDatabase];
        });
    }
    return self;
}

+ (NSString *)databasePath {
    NSString *supportDir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [supportDir stringByAppendingPathComponent:@"YTMusicUltimate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ListeningStats.sqlite"];
}

// Runs on _queue.
- (void)openDatabase {
    if (sqlite3_open([[self.class databasePath] fileSystemRepresentation], &_db) != SQLITE_OK) {
        NSLog(@"[YTMusicUltimate] Listening stats: could not open database: %s", _db ? sqlite3_errmsg(_db) : "unknown error");
        sqlite3_close(_db);
        _db = NULL;
        return;
    }

    const char *schema =
        "PRAGMA journal_mode=WAL;"
        "CREATE TABLE IF NOT EXISTS plays ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  session TEXT NOT NULL UNIQUE,"
        "  video_id TEXT NOT NULL,"
        "  title TEXT,"
        "  artist TEXT,"
        "  started_at REAL NOT NULL,"
        "  listened REAL NOT NULL DEFAULT 0,"
        "  duration REAL NOT NULL DEFAULT 0,"
        "  counted INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE INDEX IF NOT EXISTS plays_started_at ON plays(started_at);";

    char *error = NULL;
    if (sqlite3_exec(_db, schema, NULL, NULL, &error) != SQLITE_OK) {
        NSLog(@"[YTMusicUltimate] Listening stats: could not create schema: %s", error);
        sqlite3_free(error);
    }
}

#pragma mark - Writing

- (void)saveListen:(YTMUStatsListen *)listen {
    if (listen.session.length == 0 || listen.videoID.length == 0) return;
    YTMUStatsListen *snapshot = [listen copy];

    dispatch_async(_queue, ^{
        if (!self->_db) return;

        const char *sql =
            "INSERT INTO plays (session, video_id, title, artist, started_at, listened, duration, counted) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(session) DO UPDATE SET "
            "  title = excluded.title, artist = excluded.artist, listened = excluded.listened, "
            "  duration = excluded.duration, counted = excluded.counted;";

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            NSLog(@"[YTMusicUltimate] Listening stats: save failed: %s", sqlite3_errmsg(self->_db));
            return;
        }

        YTMUBindText(stmt, 1, snapshot.session);
        YTMUBindText(stmt, 2, snapshot.videoID);
        YTMUBindText(stmt, 3, snapshot.title);
        YTMUBindText(stmt, 4, snapshot.artist);
        sqlite3_bind_double(stmt, 5, snapshot.startedAt);
        sqlite3_bind_double(stmt, 6, snapshot.listened);
        sqlite3_bind_double(stmt, 7, snapshot.duration);
        sqlite3_bind_int(stmt, 8, snapshot.counted ? 1 : 0);

        if (sqlite3_step(stmt) != SQLITE_DONE) {
            NSLog(@"[YTMusicUltimate] Listening stats: save failed: %s", sqlite3_errmsg(self->_db));
        }
        sqlite3_finalize(stmt);
    });
}

- (void)clearAllWithCompletion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (self->_db) {
            sqlite3_exec(self->_db, "DELETE FROM plays;", NULL, NULL, NULL);
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Reading

// Runs on _queue.
- (NSDictionary *)summarySince:(NSTimeInterval)since {
    NSMutableDictionary *summary = [@{
        YTMUStatsSecondsKey: @0,
        YTMUStatsPlaysKey: @0,
        YTMUStatsSongsKey: @0,
        YTMUStatsArtistsKey: @0
    } mutableCopy];

    const char *sql =
        "SELECT COALESCE(SUM(listened), 0), COALESCE(SUM(counted), 0), "
        "  COUNT(DISTINCT CASE WHEN counted = 1 THEN video_id END), "
        "  COUNT(DISTINCT CASE WHEN counted = 1 AND artist <> '' THEN artist END) "
        "FROM plays WHERE started_at >= ?;";

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK) return summary;
    sqlite3_bind_double(stmt, 1, since);

    if (sqlite3_step(stmt) == SQLITE_ROW) {
        summary[YTMUStatsSecondsKey] = @(sqlite3_column_double(stmt, 0));
        summary[YTMUStatsPlaysKey] = @(sqlite3_column_int64(stmt, 1));
        summary[YTMUStatsSongsKey] = @(sqlite3_column_int64(stmt, 2));
        summary[YTMUStatsArtistsKey] = @(sqlite3_column_int64(stmt, 3));
    }
    sqlite3_finalize(stmt);
    return summary;
}

// Runs on _queue. Title and artist come from the most recent listen of each song
// (SQLite takes bare columns from the row that matched MAX()).
- (NSArray<NSDictionary *> *)topSongsSince:(NSTimeInterval)since limit:(NSInteger)limit {
    NSMutableArray *rows = [NSMutableArray array];

    const char *sql =
        "SELECT video_id, title, artist, MAX(started_at), SUM(counted) AS plays, SUM(listened) AS seconds "
        "FROM plays WHERE started_at >= ? "
        "GROUP BY video_id HAVING plays > 0 "
        "ORDER BY plays DESC, seconds DESC LIMIT ?;";

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK) return rows;
    sqlite3_bind_double(stmt, 1, since);
    sqlite3_bind_int64(stmt, 2, limit);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [rows addObject:@{
            YTMUStatsVideoIDKey: YTMUColumnText(stmt, 0),
            YTMUStatsTitleKey: YTMUColumnText(stmt, 1),
            YTMUStatsArtistKey: YTMUColumnText(stmt, 2),
            YTMUStatsPlaysKey: @(sqlite3_column_int64(stmt, 4)),
            YTMUStatsSecondsKey: @(sqlite3_column_double(stmt, 5))
        }];
    }
    sqlite3_finalize(stmt);
    return rows;
}

// Runs on _queue.
- (NSArray<NSDictionary *> *)topArtistsSince:(NSTimeInterval)since limit:(NSInteger)limit {
    NSMutableArray *rows = [NSMutableArray array];

    const char *sql =
        "SELECT artist, SUM(counted) AS plays, SUM(listened) AS seconds "
        "FROM plays WHERE started_at >= ? AND artist IS NOT NULL AND artist <> '' "
        "GROUP BY artist HAVING plays > 0 "
        "ORDER BY plays DESC, seconds DESC LIMIT ?;";

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) != SQLITE_OK) return rows;
    sqlite3_bind_double(stmt, 1, since);
    sqlite3_bind_int64(stmt, 2, limit);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [rows addObject:@{
            YTMUStatsArtistKey: YTMUColumnText(stmt, 0),
            YTMUStatsPlaysKey: @(sqlite3_column_int64(stmt, 1)),
            YTMUStatsSecondsKey: @(sqlite3_column_double(stmt, 2))
        }];
    }
    sqlite3_finalize(stmt);
    return rows;
}

- (void)loadStatsSince:(NSTimeInterval)since limit:(NSInteger)limit completion:(YTMUStatsLoadCompletion)completion {
    if (!completion) return;

    dispatch_async(_queue, ^{
        NSDictionary *summary = @{};
        NSArray *songs = @[];
        NSArray *artists = @[];

        if (self->_db) {
            summary = [self summarySince:since];
            songs = [self topSongsSince:since limit:limit];
            artists = [self topArtistsSince:since limit:limit];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(summary, songs, artists);
        });
    });
}

- (void)exportCSVWithCompletion:(void (^)(NSURL *url))completion {
    if (!completion) return;

    dispatch_async(_queue, ^{
        NSURL *resultURL = nil;

        if (self->_db) {
            const char *sql =
                "SELECT started_at, video_id, title, artist, listened, duration, counted "
                "FROM plays ORDER BY started_at;";

            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
                NSMutableString *csv = [NSMutableString stringWithString:@"started_at,video_id,title,artist,listened_seconds,duration_seconds,counted_as_play\n"];

                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    NSDate *date = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_double(stmt, 0)];
                    [csv appendFormat:@"%@,%@,%@,%@,%.0f,%.0f,%d\n",
                        [formatter stringFromDate:date],
                        YTMUCSVField(YTMUColumnText(stmt, 1)),
                        YTMUCSVField(YTMUColumnText(stmt, 2)),
                        YTMUCSVField(YTMUColumnText(stmt, 3)),
                        sqlite3_column_double(stmt, 4),
                        sqlite3_column_double(stmt, 5),
                        sqlite3_column_int(stmt, 6)];
                }
                sqlite3_finalize(stmt);

                NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"YouTubeMusic-listening-history.csv"]];
                if ([csv writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                    resultURL = url;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(resultURL);
        });
    });
}

@end
