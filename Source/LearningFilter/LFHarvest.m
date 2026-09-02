#import "LFHarvest.h"
#import "LFCommon.h"
#import "LFMetadata.h"
#import "LFSubscriptionStore.h"

NSString *const LFWhitelistDidChangeNotification = @"LFWhitelistDidChangeNotification";

// Time-bounded: the flag is refreshed while the Subscriptions feed lays out and
// lapses on its own, so a stale "we are on the subscriptions tab" can never
// switch filtering off for the rest of the session.
static NSTimeInterval gSubscriptionsSurfaceStamp = 0;
static const NSTimeInterval LFSubscriptionsSurfaceTTL = 2.0;

BOOL LFOnSubscriptionsSurface(void) {
    return gSubscriptionsSurfaceStamp > 0 &&
           NSDate.timeIntervalSinceReferenceDate - gSubscriptionsSurfaceStamp < LFSubscriptionsSurfaceTTL;
}

void LFSetOnSubscriptionsSurface(BOOL onSurface) {
    gSubscriptionsSurfaceStamp = onSurface ? NSDate.timeIntervalSinceReferenceDate : 0;
}

static void LFNotifyWhitelistChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LFWhitelistDidChangeNotification object:nil];
    });
}

#pragma mark - Description parsing

// A protobuf text dump quotes every string field. Channel titles are the only
// quoted strings that sit next to a channel id and read like a title, so the
// pairing below stays close: a title is only accepted within a few lines of the
// id it is attributed to.
static BOOL LFLooksLikeChannelTitle(NSString *value) {
    if (value.length == 0 || value.length > 80)
        return NO;
    if ([value hasPrefix:@"http"] || [value hasPrefix:@"//"] || [value containsString:@"://"])
        return NO;
    // A canonical URL such as "/@matha" sits on the same line as the channel id
    // it belongs to, so it is the first thing the search would otherwise find.
    // It identifies the channel, but it is not its title.
    if ([value hasPrefix:@"/"] || [value hasPrefix:@"@"] || LFNormalizeHandle(value))
        return NO;
    if (LFNormalizeChannelId(value))
        return NO;
    // Endpoint identifiers ("FEsubscriptions", "UCBR8-60-B28hp2BmDPdntcQ") and
    // opaque tokens are not titles.
    if ([value hasPrefix:@"FE"] || [value hasPrefix:@"SC"] || [value hasPrefix:@"VL"])
        return NO;
    if ([value rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound)
        return NO;
    // A long unbroken base64url run is a token, not a name.
    if (value.length > 24 && [value rangeOfString:@" "].location == NSNotFound)
        return NO;
    return YES;
}

static NSArray<NSString *> *LFQuotedStringsInLine(NSString *line) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\"([^\"]{1,120})\"" options:0 error:nil];
    });

    NSMutableArray<NSString *> *values = [NSMutableArray array];
    [regex enumerateMatchesInString:line
                            options:0
                              range:NSMakeRange(0, line.length)
                         usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags,
                                      __unused BOOL *stop) {
                             if (match.numberOfRanges > 1)
                                 [values addObject:[line substringWithRange:[match rangeAtIndex:1]]];
                         }];
    return values;
}

// The guide carries more than subscriptions (pivot bar, "Explore", history).
// Those entries use FE-prefixed browse ids rather than UC ids, so restricting to
// UC ids already scopes the harvest to channels; where the dump marks the
// subscription section explicitly we narrow further.
static NSString *LFSubscriptionScope(NSString *description) {
    NSRange marker = [description rangeOfString:@"subscription" options:NSCaseInsensitiveSearch];
    if (marker.location == NSNotFound)
        return description;
    return [description substringFromIndex:marker.location];
}

BOOL LFHarvestFromDescription(NSString *description) {
    if (![description isKindOfClass:[NSString class]] || description.length == 0)
        return NO;

    NSString *scope = LFSubscriptionScope(description);
    NSArray<NSString *> *lines = [scope componentsSeparatedByString:@"\n"];
    if (lines.count == 0)
        return NO;

    NSMutableOrderedSet<NSString *> *channelIds = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *handles = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];

    // Cache the quoted strings per line once; the dump can be large.
    NSMutableArray<NSArray<NSString *> *> *quotedPerLine = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *line in lines)
        [quotedPerLine addObject:([line rangeOfString:@"\""].location == NSNotFound ? @[]
                                                                                    : LFQuotedStringsInLine(line))];

    const NSInteger window = 6;
    for (NSInteger index = 0; index < (NSInteger)lines.count; index++) {
        NSString *line = lines[(NSUInteger)index];
        NSArray<NSString *> *idsOnLine = LFChannelIdsInString(line);
        for (NSString *handle in LFHandlesInString(line))
            [handles addObject:handle];
        if (idsOnLine.count == 0)
            continue;

        for (NSString *channelId in idsOnLine)
            [channelIds addObject:channelId];

        // Look for the title attached to this entry, nearest line first.
        NSString *title = nil;
        for (NSInteger offset = 0; offset <= window && !title; offset++) {
            for (NSInteger direction = -1; direction <= 1 && !title; direction += 2) {
                NSInteger probe = index + (offset == 0 ? 0 : offset * direction);
                if (probe < 0 || probe >= (NSInteger)lines.count)
                    continue;
                for (NSString *quoted in quotedPerLine[(NSUInteger)probe]) {
                    if (LFLooksLikeChannelTitle(quoted)) {
                        title = quoted;
                        break;
                    }
                }
                if (offset == 0)
                    break;  // offset 0 probes the same line twice otherwise
            }
        }
        if (title)
            [names addObject:title];
    }

    if (channelIds.count == 0 && handles.count == 0)
        return NO;

    BOOL changed = [[LFSubscriptionStore sharedInstance] recordSubscribedChannelIds:channelIds.array
                                                                           handles:handles.array
                                                                             names:names.array];
    if (changed)
        LFNotifyWhitelistChanged();
    return changed;
}

#pragma mark - Cell metadata

BOOL LFHarvestFromInfo(NSDictionary<NSString *, NSString *> *info) {
    NSString *channelId = info[LFInfoChannelIdKey];
    NSString *handle = info[LFInfoHandleKey];
    NSString *name = info[LFInfoChannelKey];
    if (channelId.length == 0 && handle.length == 0 && name.length == 0)
        return NO;

    BOOL changed = [[LFSubscriptionStore sharedInstance] recordSubscribedChannelId:channelId
                                                                           handle:handle
                                                                             name:name];
    if (changed)
        LFNotifyWhitelistChanged();
    return changed;
}
