#import "ListeningStatsController.h"
#import "../Stats/YTMUStatsStore.h"
#import "../Stats/YTMUStatsTracker.h"

typedef NS_ENUM(NSInteger, YTMUStatsSection) {
    YTMUStatsSectionOverview,
    YTMUStatsSectionSongs,
    YTMUStatsSectionArtists,
    YTMUStatsSectionSettings,
    YTMUStatsSectionCount
};

typedef NS_ENUM(NSInteger, YTMUStatsSettingsRow) {
    YTMUStatsSettingsRowToggle,
    YTMUStatsSettingsRowExport,
    YTMUStatsSettingsRowClear,
    YTMUStatsSettingsRowCount
};

static const NSInteger kTopLimit = 10;
static const NSInteger kOverviewRows = 4;

static NSString *YTMUFormatListeningTime(double seconds) {
    static NSDateComponentsFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateComponentsFormatter alloc] init];
        formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
        formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleShort;
        formatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropLeading;
    });

    // Round to whole minutes so short listens don't show as "0 min" too eagerly.
    NSTimeInterval rounded = round(seconds / 60.0) * 60.0;
    return [formatter stringFromTimeInterval:rounded] ?: @"";
}

static NSString *YTMUFormatPlays(NSInteger plays) {
    if (plays == 1) return STATS_LOC(@"STATS_ONE_PLAY", @"1 play");
    return [NSString stringWithFormat:STATS_LOC(@"STATS_PLAYS_FORMAT", @"%ld plays"), (long)plays];
}

@interface ListeningStatsController ()
@property (nonatomic, strong) UISegmentedControl *rangeControl;
@property (nonatomic, copy) NSDictionary *summary;
@property (nonatomic, copy) NSArray<NSDictionary *> *topSongs;
@property (nonatomic, copy) NSArray<NSDictionary *> *topArtists;
@property (nonatomic, assign) NSUInteger loadGeneration;
@end

@implementation ListeningStatsController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = STATS_LOC(@"LISTENING_STATS", @"Listening Stats");
    self.summary = @{};
    self.topSongs = @[];
    self.topArtists = @[];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    self.rangeControl = [[UISegmentedControl alloc] initWithItems:@[
        STATS_LOC(@"STATS_RANGE_WEEK", @"7 days"),
        STATS_LOC(@"STATS_RANGE_MONTH", @"30 days"),
        STATS_LOC(@"STATS_RANGE_ALL", @"All time")
    ]];
    self.rangeControl.selectedSegmentIndex = 0;
    self.rangeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rangeControl addTarget:self action:@selector(rangeChanged:) forControlEvents:UIControlEventValueChanged];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 56)];
    [header addSubview:self.rangeControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.rangeControl.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [self.rangeControl.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [self.rangeControl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
    ]];
    self.tableView.tableHeaderView = header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadStats];
}

#pragma mark - Data

- (NSTimeInterval)selectedRangeStart {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    switch (self.rangeControl.selectedSegmentIndex) {
        case 0: return now - 7 * 24 * 60 * 60;
        case 1: return now - 30 * 24 * 60 * 60;
        default: return 0;
    }
}

- (void)reloadStats {
    NSUInteger generation = ++self.loadGeneration;

    [[YTMUStatsStore sharedStore] loadStatsSince:[self selectedRangeStart] limit:kTopLimit completion:^(NSDictionary *summary, NSArray<NSDictionary *> *topSongs, NSArray<NSDictionary *> *topArtists) {
        // Ignore results from an older range if the user switched quickly.
        if (generation != self.loadGeneration) return;

        self.summary = summary;
        self.topSongs = topSongs;
        self.topArtists = topArtists;
        [self.tableView reloadData];
    }];
}

- (void)rangeChanged:(UISegmentedControl *)sender {
    [self reloadStats];
}

- (BOOL)trackingEnabled {
    id value = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][YTMUStatsEnabledKey];
    return value == nil || [value boolValue];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return YTMUStatsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case YTMUStatsSectionOverview: return kOverviewRows;
        case YTMUStatsSectionSongs: return MAX((NSInteger)self.topSongs.count, (NSInteger)1); // 1 = "nothing yet" row
        case YTMUStatsSectionArtists: return MAX((NSInteger)self.topArtists.count, (NSInteger)1);
        case YTMUStatsSectionSettings: return YTMUStatsSettingsRowCount;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case YTMUStatsSectionOverview: return STATS_LOC(@"STATS_OVERVIEW", @"Overview");
        case YTMUStatsSectionSongs: return STATS_LOC(@"STATS_TOP_SONGS", @"Top songs");
        case YTMUStatsSectionArtists: return STATS_LOC(@"STATS_TOP_ARTISTS", @"Top artists");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == YTMUStatsSectionSettings) {
        return STATS_LOC(@"STATS_FOOTER", @"A song counts as a play after 30 seconds of listening, or half of it for very short songs. Your history is stored only on this device.");
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case YTMUStatsSectionOverview: return [self overviewCellForRow:indexPath.row];
        case YTMUStatsSectionSongs: return [self songCellForRow:indexPath.row];
        case YTMUStatsSectionArtists: return [self artistCellForRow:indexPath.row];
        case YTMUStatsSectionSettings: return [self settingsCellForRow:indexPath.row];
        default: return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    }
}

- (UITableViewCell *)overviewCellForRow:(NSInteger)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"statsOverviewCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"statsOverviewCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    NSArray *rows = @[
        @[STATS_LOC(@"STATS_LISTENING_TIME", @"Listening time"), @"clock", YTMUFormatListeningTime([self.summary[YTMUStatsSecondsKey] doubleValue])],
        @[STATS_LOC(@"STATS_PLAYS", @"Plays"), @"play.circle", [NSString stringWithFormat:@"%ld", (long)[self.summary[YTMUStatsPlaysKey] integerValue]]],
        @[STATS_LOC(@"STATS_SONGS", @"Different songs"), @"music.note", [NSString stringWithFormat:@"%ld", (long)[self.summary[YTMUStatsSongsKey] integerValue]]],
        @[STATS_LOC(@"STATS_ARTISTS", @"Different artists"), @"music.mic", [NSString stringWithFormat:@"%ld", (long)[self.summary[YTMUStatsArtistsKey] integerValue]]]
    ];

    NSArray *data = rows[row];
    cell.textLabel.text = data[0];
    cell.imageView.image = [UIImage systemImageNamed:data[1]];
    cell.detailTextLabel.text = data[2];
    return cell;
}

- (UITableViewCell *)emptyCellWithText:(NSString *)text {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"statsEmptyCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"statsEmptyCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.numberOfLines = 0;
    }
    cell.textLabel.text = text;
    return cell;
}

- (UITableViewCell *)rankedCellWithRank:(NSInteger)rank title:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"statsRankedCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"statsRankedCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 0;
    }
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)rank, title];
    cell.detailTextLabel.text = detail;
    return cell;
}

- (UITableViewCell *)songCellForRow:(NSInteger)row {
    if (self.topSongs.count == 0) {
        return [self emptyCellWithText:STATS_LOC(@"STATS_NO_SONGS", @"No plays in this period yet. Play some music and check back.")];
    }

    NSDictionary *song = self.topSongs[row];
    NSString *title = [song[YTMUStatsTitleKey] length] > 0 ? song[YTMUStatsTitleKey] : song[YTMUStatsVideoIDKey];

    NSMutableArray *parts = [NSMutableArray array];
    if ([song[YTMUStatsArtistKey] length] > 0) [parts addObject:song[YTMUStatsArtistKey]];
    [parts addObject:YTMUFormatPlays([song[YTMUStatsPlaysKey] integerValue])];
    [parts addObject:YTMUFormatListeningTime([song[YTMUStatsSecondsKey] doubleValue])];

    return [self rankedCellWithRank:row + 1 title:title detail:[parts componentsJoinedByString:@" · "]];
}

- (UITableViewCell *)artistCellForRow:(NSInteger)row {
    if (self.topArtists.count == 0) {
        return [self emptyCellWithText:STATS_LOC(@"STATS_NO_ARTISTS", @"No artists in this period yet.")];
    }

    NSDictionary *artist = self.topArtists[row];
    NSString *detail = [NSString stringWithFormat:@"%@ · %@",
                        YTMUFormatPlays([artist[YTMUStatsPlaysKey] integerValue]),
                        YTMUFormatListeningTime([artist[YTMUStatsSecondsKey] doubleValue])];

    return [self rankedCellWithRank:row + 1 title:artist[YTMUStatsArtistKey] detail:detail];
}

- (UITableViewCell *)settingsCellForRow:(NSInteger)row {
    // Each settings row has its own look, so they are not reused.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    if (row == YTMUStatsSettingsRowToggle) {
        cell.textLabel.text = STATS_LOC(@"STATS_TRACK_LISTENING", @"Track listening");
        cell.imageView.image = [UIImage systemImageNamed:@"waveform"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        ABCSwitch *toggle = [[NSClassFromString(@"ABCSwitch") alloc] init];
        toggle.onTintColor = [UIColor colorWithRed:30.0/255.0 green:150.0/255.0 blue:245.0/255.0 alpha:1.0];
        toggle.on = [self trackingEnabled];
        [toggle addTarget:self action:@selector(toggleTracking:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (row == YTMUStatsSettingsRowExport) {
        cell.textLabel.text = STATS_LOC(@"STATS_EXPORT", @"Export history (CSV)");
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    } else if (row == YTMUStatsSettingsRowClear) {
        cell.textLabel.text = STATS_LOC(@"STATS_CLEAR", @"Clear listening history");
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor systemRedColor];
    }

    return cell;
}

#pragma mark - Table view delegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == YTMUStatsSectionSettings && indexPath.row != YTMUStatsSettingsRowToggle;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != YTMUStatsSectionSettings) return;

    if (indexPath.row == YTMUStatsSettingsRowExport) {
        [self exportFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.row == YTMUStatsSettingsRowClear) {
        [self confirmClear];
    }
}

#pragma mark - Actions

- (void)toggleTracking:(ABCSwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"YTMUltimate"]];
    prefs[YTMUStatsEnabledKey] = @(sender.isOn);
    [defaults setObject:prefs forKey:@"YTMUltimate"];

    YTMUStatsTracker *tracker = [YTMUStatsTracker sharedTracker];
    if (!sender.isOn) [tracker endCurrent];
    [tracker reloadPreferences];
}

- (void)exportFromCell:(UITableViewCell *)cell {
    [[YTMUStatsStore sharedStore] exportCSVWithCompletion:^(NSURL *url) {
        if (!url) return;

        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = cell ?: self.view;
        share.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:STATS_LOC(@"STATS_CLEAR", @"Clear listening history")
                                                                   message:STATS_LOC(@"STATS_CLEAR_MESSAGE", @"This deletes all your listening stats on this device. It can't be undone.")
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:STATS_LOC(@"STATS_CLEAR_CONFIRM", @"Clear") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YTMUStatsTracker sharedTracker] discardCurrent];
        [[YTMUStatsStore sharedStore] clearAllWithCompletion:^{
            [self reloadStats];
        }];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
