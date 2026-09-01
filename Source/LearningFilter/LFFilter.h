// Learning Filter — the one place that decides whether content may be shown.
//
// Requirement 8: home, search, Shorts, related and every other recommendation
// surface share this decision rather than each growing its own rules.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, LFSurface) {
    LFSurfaceHome = 0,
    LFSurfaceSearch,
    LFSurfaceShorts,
    LFSurfaceRelated,
    LFSurfaceOther,
};

typedef NS_ENUM(NSUInteger, LFDecision) {
    LFDecisionAllow = 0,  // subscribed channel, or filtering is inactive
    LFDecisionHide,       // identified, and not a subscribed channel
    LFDecisionUnknown,    // no channel identity could be read
};

// Master gate: the filter is on, and a whitelist actually exists. With no
// whitelist (signed out, never synced) filtering stays inert — requirement 9.
FOUNDATION_EXPORT BOOL LFFilteringActive(void);
FOUNDATION_EXPORT BOOL LFSurfaceEnabled(LFSurface surface);

// The common predicate. Requirement 4: allowed == currently subscribed.
FOUNDATION_EXPORT BOOL LFIsSubscribedToChannel(NSString *_Nullable channelId, NSString *_Nullable handle,
                                               NSString *_Nullable channelName);
FOUNDATION_EXPORT BOOL LFIsAllowedChannel(NSString *_Nullable channelId, NSString *_Nullable handle,
                                          NSString *_Nullable channelName);

// Decision for one extracted metadata dictionary (see LFMetadata.h).
FOUNDATION_EXPORT LFDecision LFDecisionForInfo(NSDictionary<NSString *, NSString *> *_Nullable info);

// Decision for a feed node. Returns LFDecisionAllow for anything that is not a
// video-like item, so shelves, headers and chrome are never touched.
FOUNDATION_EXPORT LFDecision LFDecisionForNode(id _Nullable node);

// Convenience: should this node be hidden on this surface? Applies the strict
// setting, which turns "unknown identity" into "hide" (requirement 14).
FOUNDATION_EXPORT BOOL LFShouldHideNode(id _Nullable node, LFSurface surface);
FOUNDATION_EXPORT BOOL LFShouldHideInfo(NSDictionary<NSString *, NSString *> *_Nullable info, LFSurface surface);

// YES when the node is the kind of thing the filter is meant to act on.
FOUNDATION_EXPORT BOOL LFNodeLooksLikeVideo(id _Nullable node);

NS_ASSUME_NONNULL_END
