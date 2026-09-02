#import "LFFilter.h"
#import "LFCommon.h"
#import "LFMetadata.h"
#import "LFSubscriptionStore.h"

static NSUInteger gSettingsEpoch = 0;

// Strict mode hides anything whose channel cannot be read. That is right when
// identification usually works and occasionally does not. It is catastrophic
// when identification stops working altogether — a YouTube update changes a
// payload shape, say — because then it hides everything and leaves an empty app
// with no obvious way back.
//
// So strict hiding gives up after this many unidentifiable items in a row, and
// resumes the moment anything is identified again. In normal operation the
// counter never gets near the threshold: one recognised item resets it.
static const NSUInteger LFStrictSuspensionThreshold = 25;
static NSUInteger gConsecutiveUnknown = 0;
static BOOL gStrictSuspended = NO;

BOOL LFStrictSuspended(void) {
    return gStrictSuspended;
}

void LFResetStrictSuspension(void) {
    gConsecutiveUnknown = 0;
    gStrictSuspended = NO;
}

static void LFNoteDecision(LFDecision decision) {
    if (decision == LFDecisionUnknown) {
        if (++gConsecutiveUnknown >= LFStrictSuspensionThreshold)
            gStrictSuspended = YES;
        return;
    }
    gConsecutiveUnknown = 0;
    gStrictSuspended = NO;
}

NSUInteger LFFilterEpoch(void) {
    // Both terms only ever increase, so any change to either moves the sum. That
    // is all a cache needs: not an identity, just "is this still the same world".
    return gSettingsEpoch + [LFSubscriptionStore sharedInstance].generation;
}

void LFBumpFilterEpoch(void) {
    gSettingsEpoch++;
}

BOOL LFFilteringActive(void) {
    if (!LFBoolDefaultYes(LFEnabledKey))
        return NO;
    // Requirement 9: without a signed-in account there is no subscription list,
    // so there is no whitelist to apply. Filtering everything away in that state
    // would leave a blank app with no way back, so it stays inert instead and the
    // settings screen says so.
    return ![[LFSubscriptionStore sharedInstance] isEmpty];
}

BOOL LFSurfaceEnabled(LFSurface surface) {
    switch (surface) {
        case LFSurfaceHome:
            return LFBoolDefaultYes(LFFilterHomeKey);
        case LFSurfaceSearch:
            return LFBoolDefaultYes(LFFilterSearchKey);
        case LFSurfaceShorts:
            return LFBoolDefaultYes(LFFilterShortsKey);
        case LFSurfaceRelated:
            return LFBoolDefaultYes(LFFilterRelatedKey);
        case LFSurfaceOther:
            // Any recommendation surface not separately switchable follows the
            // home setting, which is the general "recommendations" toggle.
            return LFBoolDefaultYes(LFFilterHomeKey);
    }
    return YES;
}

BOOL LFIsSubscribedToChannel(NSString *channelId, NSString *handle, NSString *channelName) {
    LFSubscriptionStore *store = [LFSubscriptionStore sharedInstance];

    // Identifiers are ranked, not OR-ed. Display names are the weakest form and
    // are harvested by proximity, so a name must never override a channel id that
    // is present and simply not subscribed — that is how a lookalike channel
    // would slip through.
    BOOL hasStrongIdentity = channelId.length > 0 || handle.length > 0;
    if (hasStrongIdentity) {
        if ([store isSubscribedToChannelId:channelId] || [store isSubscribedToHandle:handle])
            return YES;
        // Unless the whitelist itself holds no strong identifiers, in which case
        // names are all there is to compare against.
        if (store.subscribedChannelIds.count > 0 || store.subscribedHandles.count > 0)
            return NO;
    }

    return [store isSubscribedToChannelName:channelName];
}

BOOL LFIsAllowedChannel(NSString *channelId, NSString *handle, NSString *channelName) {
    // Whitelist == subscriptions. The indirection is kept because every surface
    // calls this one and the equivalence is the specification, not an accident.
    return LFIsSubscribedToChannel(channelId, handle, channelName);
}

LFDecision LFDecisionForInfo(NSDictionary<NSString *, NSString *> *info) {
    NSString *channelId = info[LFInfoChannelIdKey];
    NSString *handle = info[LFInfoHandleKey];
    NSString *channelName = info[LFInfoChannelKey];

    if (channelId.length == 0 && handle.length == 0 && channelName.length == 0)
        return LFDecisionUnknown;

    return LFIsAllowedChannel(channelId, handle, channelName) ? LFDecisionAllow : LFDecisionHide;
}

BOOL LFNodeLooksLikeVideo(id node) {
    if (!node)
        return NO;

    NSString *className = NSStringFromClass([node class]).lowercaseString;

    // Containers hold many items; hiding one would take unrelated content with it.
    for (NSString *container in @[@"collection", @"reorderable", @"scrollablepage", @"shelf", @"section"]) {
        if ([className containsString:container])
            return NO;
    }

    BOOL videoLike = [className containsString:@"video"] || [className containsString:@"short"] ||
                     [className containsString:@"reel"];
    BOOL contentNode = [className containsString:@"node"] || [className containsString:@"item"] ||
                       [className containsString:@"cell"];
    if (videoLike && contentNode)
        return YES;

    // Element-rendered cells are generic: they are only interesting when the
    // metadata layer actually found a video in them.
    if ([className containsString:@"elmcellnode"]) {
        NSDictionary *info = LFVideoInfoFromNode(node);
        return info[LFInfoVideoIdKey] != nil || info[LFInfoChannelIdKey] != nil;
    }

    return NO;
}

LFDecision LFDecisionForNode(id node) {
    if (!LFNodeLooksLikeVideo(node))
        return LFDecisionAllow;
    return LFDecisionForInfo(LFVideoInfoFromNode(node));
}

BOOL LFShouldHideInfo(NSDictionary<NSString *, NSString *> *info, LFSurface surface) {
    if (!LFFilteringActive() || !LFSurfaceEnabled(surface))
        return NO;

    LFDecision decision = LFDecisionForInfo(info);
    LFNoteDecision(decision);

    // Dry run still computes and records the decision, but nothing is hidden.
    if (LFDryRunEnabled())
        return NO;

    switch (decision) {
        case LFDecisionAllow:
            return NO;
        case LFDecisionHide:
            return YES;
        case LFDecisionUnknown:
            // An unreadable channel is never given the benefit of the doubt while
            // strict mode is on — unless the safety valve above has tripped.
            if (!LFBoolDefaultYes(LFStrictKey))
                return NO;
            if (gStrictSuspended && LFBoolDefaultYes(LFStrictFallbackKey))
                return NO;
            return YES;
    }
    return NO;
}

BOOL LFShouldHideNode(id node, LFSurface surface) {
    if (!LFFilteringActive() || !LFSurfaceEnabled(surface))
        return NO;
    if (!LFNodeLooksLikeVideo(node))
        return NO;
    return LFShouldHideInfo(LFVideoInfoFromNode(node), surface);
}
