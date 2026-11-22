#import <UIKit/UIKit.h>
#import "../Headers/Localization.h"

// Like LOC(), but falls back to the English text when a language file has no
// translation for the key yet.
#define STATS_LOC(key, english) [NSBundle.ytmu_defaultBundle localizedStringForKey:(key) value:(english) table:nil]

@interface ListeningStatsController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@end
