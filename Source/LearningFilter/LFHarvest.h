// Learning Filter — building the whitelist out of YouTube's own data.
//
// Requirement 4: the whitelist is the account's current subscription list, not a
// list the user maintains. Three sources feed it, strongest first:
//
//   1. The guide response. YouTube fetches it on launch; it carries the whole
//      subscription list as browse endpoints (UC... ids) plus channel titles.
//   2. Feed cells shown on the Subscriptions tab. Everything there is subscribed
//      by definition, and a cell exposes id, handle and display name together,
//      so it is the only source that pairs all three exactly.
//   3. Subscribe buttons reported as already subscribed.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Parses a protobuf text description (what -[GPBMessage description] returns).
// Returns YES when the whitelist grew.
FOUNDATION_EXPORT BOOL LFHarvestFromDescription(NSString *_Nullable description);

// Records one channel known to be subscribed, from extracted cell metadata.
FOUNDATION_EXPORT BOOL LFHarvestFromInfo(NSDictionary<NSString *, NSString *> *_Nullable info);

// True while the Subscriptions tab is the visible feed.
FOUNDATION_EXPORT BOOL LFOnSubscriptionsSurface(void);
FOUNDATION_EXPORT void LFSetOnSubscriptionsSurface(BOOL onSurface);

// Posted when the whitelist changes so visible feeds can be re-evaluated.
FOUNDATION_EXPORT NSString *const LFWhitelistDidChangeNotification;

NS_ASSUME_NONNULL_END
