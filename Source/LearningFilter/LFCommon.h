// Learning Filter — shared definitions.
//
// Whitelist mode for uYouEnhanced: only channels the signed-in YouTube account is
// *currently subscribed to* may supply content (home, search, Shorts, related).
// The whitelist is never authored by hand: it is harvested from YouTube's own
// subscription data (guide response, subscription feed, subscribe button state).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - NSUserDefaults keys

// Master switch. Default ON.
static NSString *const LFEnabledKey = @"learningFilter_enabled";
// Per-surface switches. Default ON.
static NSString *const LFFilterHomeKey = @"learningFilter_home_enabled";
static NSString *const LFFilterSearchKey = @"learningFilter_search_enabled";
static NSString *const LFFilterShortsKey = @"learningFilter_shorts_enabled";
static NSString *const LFFilterRelatedKey = @"learningFilter_related_enabled";
// Hide anything whose channel identity cannot be resolved. Default ON (fail closed).
static NSString *const LFStrictKey = @"learningFilter_strict_enabled";
// Block new channel subscriptions. Default ON.
static NSString *const LFBlockSubscribeKey = @"learningFilter_blockSubscribe_enabled";
// Allow at most one signed-in account. Default ON.
static NSString *const LFSingleAccountKey = @"learningFilter_singleAccount_enabled";

// Harvested whitelist storage.
static NSString *const LFSubscribedChannelIdsKey = @"learningFilter_subscribedChannelIds";
static NSString *const LFSubscribedHandlesKey = @"learningFilter_subscribedHandles";
static NSString *const LFSubscribedNamesKey = @"learningFilter_subscribedNames";
static NSString *const LFManualNamesKey = @"learningFilter_manualNames";
static NSString *const LFLastSyncKey = @"learningFilter_lastSync";
// Set once a YouTube account has been observed; drives the single-account rule.
static NSString *const LFAccountBoundKey = @"learningFilter_accountBound";

#pragma mark - Preference helpers

// Options that default to ON when the user has never touched them.
static inline BOOL LFBoolDefaultYes(NSString *key) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:key] == nil ? YES : [defaults boolForKey:key];
}

static inline BOOL LFBoolDefaultNo(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

NS_ASSUME_NONNULL_END
