#import "LFMetadata.h"
#import "LFSubscriptionStore.h"

#import <string.h>

#import <objc/runtime.h>

NSString *const LFInfoVideoIdKey = @"id";
NSString *const LFInfoTitleKey = @"title";
NSString *const LFInfoChannelKey = @"channel";
NSString *const LFInfoChannelIdKey = @"channelId";
NSString *const LFInfoHandleKey = @"handle";

@interface NSObject (LFFormattedString)
- (NSString *)stringWithFormattingRemoved;
- (NSString *)string;
@end

typedef NS_ENUM(NSUInteger, LFFieldRole) {
    LFFieldRoleNone = 0,
    LFFieldRoleVideoId,
    LFFieldRoleTitle,
    LFFieldRoleChannel,
    LFFieldRoleChannelId,
    LFFieldRoleHandle,
};

#pragma mark - Runtime access helpers

id LFValueForKey(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;

    @try {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector])
            return nil;

        Method method = class_getInstanceMethod(object_getClass(object), selector);
        if (!method)
            return nil;

        // Only object-returning, zero-argument getters. Anything else could be a
        // primitive accessor whose return value we would misread, or a mutator.
        const char *encoding = method_getTypeEncoding(method);
        if (!encoding || encoding[0] != '@')
            return nil;
        if (method_getNumberOfArguments(method) != 2)
            return nil;

        return ((id(*)(id, SEL))method_getImplementation(method))(object, selector);
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

NSString *LFTextFromValue(id value) {
    if (!value)
        return nil;

    if ([value isKindOfClass:[NSString class]])
        return value;

    if ([value isKindOfClass:[NSURL class]])
        return ((NSURL *)value).absoluteString;

    if ([value isKindOfClass:[NSAttributedString class]])
        return ((NSAttributedString *)value).string;

    // YTIFormattedString and friends.
    for (NSString *key in @[@"stringWithFormattingRemoved", @"string", @"text", @"accessibilityLabel"]) {
        id text = LFValueForKey(value, key);
        if ([text isKindOfClass:[NSString class]] && ((NSString *)text).length > 0)
            return text;
        if ([text isKindOfClass:[NSAttributedString class]] && ((NSAttributedString *)text).length > 0)
            return ((NSAttributedString *)text).string;
    }

    return nil;
}

#pragma mark - Pattern scanning

static NSRegularExpression *LFChannelIdRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}" options:0 error:nil];
    });
    return regex;
}

static NSRegularExpression *LFHandleRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Handles appear as "/@name" in URLs and as "@name" in canonical fields.
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[/\"' ])(@[A-Za-z0-9._-]{3,30})(?:[^A-Za-z0-9._-]|$)"
                                                          options:0
                                                            error:nil];
    });
    return regex;
}

NSArray<NSString *> *LFChannelIdsInString(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length < 24)
        return @[];

    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    [LFChannelIdRegex() enumerateMatchesInString:text
                                         options:0
                                           range:NSMakeRange(0, text.length)
                                      usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags,
                                                   __unused BOOL *stop) {
                                          NSUInteger end = NSMaxRange(match.range);
                                          if (end < text.length) {
                                              // Reject a longer base64url run that merely begins with "UC".
                                              unichar next = [text characterAtIndex:end];
                                              if ((next >= 'A' && next <= 'Z') || (next >= 'a' && next <= 'z') ||
                                                  (next >= '0' && next <= '9') || next == '_' || next == '-')
                                                  return;
                                          }
                                          [found addObject:[text substringWithRange:match.range]];
                                      }];
    return found.array;
}

NSArray<NSString *> *LFHandlesInString(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length < 4)
        return @[];

    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    [LFHandleRegex() enumerateMatchesInString:text
                                      options:0
                                        range:NSMakeRange(0, text.length)
                                   usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags,
                                                __unused BOOL *stop) {
                                       if (match.numberOfRanges < 2)
                                           return;
                                       NSString *handle = LFNormalizeHandle([text substringWithRange:[match rangeAtIndex:1]]);
                                       if (handle)
                                           [found addObject:handle];
                                   }];
    return found.array;
}

// Identifiers and URLs sit in protobuf payloads as plain ASCII, so they can be
// found by scanning bytes rather than by decoding a message whose field
// numbering changes between YouTube versions.
//
// These run on every element renderer the app builds, which during a fast scroll
// is thousands per second, so they work directly on the byte buffer. Building an
// NSString first — let alone one character at a time — is the difference between
// a scan that disappears into the noise and one that visibly stalls the feed.

static BOOL LFIsChannelIdCharacter(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
           byte == '_' || byte == '-';
}

// Every "UCxxxxxxxxxxxxxxxxxxxxxx" in the buffer, in order, without duplicates.
// A run longer than 24 characters is skipped: it is some other token that merely
// starts with "UC".
static NSArray<NSString *> *LFChannelIdsInBytes(const uint8_t *bytes, NSUInteger length, NSUInteger limit) {
    if (!bytes || length < 24)
        return @[];

    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    for (NSUInteger index = 0; index + 24 <= length; index++) {
        if (bytes[index] != 'U' || bytes[index + 1] != 'C')
            continue;
        if (index > 0 && LFIsChannelIdCharacter(bytes[index - 1]))
            continue;

        NSUInteger end = index + 2;
        while (end < length && LFIsChannelIdCharacter(bytes[end]))
            end++;

        if (end - index == 24) {
            [found addObject:[[NSString alloc] initWithBytes:bytes + index length:24 encoding:NSASCIIStringEncoding]];
            if (limit > 0 && found.count >= limit)
                break;
        }
        // Either way, jump past the run. Any "UC" inside it is preceded by an
        // identifier character and would be rejected on its own account, so
        // rescanning it byte by byte only costs time.
        index = end - 1;
    }
    return found.array;
}

static BOOL LFIsHandleCharacter(uint8_t byte) {
    return (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') || (byte >= '0' && byte <= '9') ||
           byte == '.' || byte == '_' || byte == '-';
}

// Handles appear as "/@name" in canonical URLs. A bare "@name" is not accepted
// here: in a payload it is as likely to be part of a title or a comment.
static NSArray<NSString *> *LFHandlesInBytes(const uint8_t *bytes, NSUInteger length, NSUInteger limit) {
    if (!bytes || length < 5)
        return @[];

    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    for (NSUInteger index = 0; index + 5 <= length; index++) {
        if (bytes[index] != '/' || bytes[index + 1] != '@')
            continue;

        NSUInteger start = index + 1;
        NSUInteger end = start + 1;
        while (end < length && LFIsHandleCharacter(bytes[end]))
            end++;

        NSUInteger handleLength = end - start;
        if (handleLength < 4 || handleLength > 31)
            continue;

        NSString *handle = [[NSString alloc] initWithBytes:bytes + start
                                                    length:handleLength
                                                  encoding:NSASCIIStringEncoding];
        handle = LFNormalizeHandle(handle);
        if (handle)
            [found addObject:handle];
        if (limit > 0 && found.count >= limit)
            break;
        index = end - 1;
    }
    return found.array;
}

// The 11-character video id out of an embedded thumbnail URL. That URL is the
// most dependable marker that a payload describes a video at all.
static NSString *LFVideoIdInBytes(const uint8_t *bytes, NSUInteger length) {
    static const char *const prefixes[] = {"i.ytimg.com/vi/", "i.ytimg.com/vi_webp/", "/shorts/", "?v="};
#define LFVideoIdPrefixCount 4
    static const NSUInteger prefixCount = LFVideoIdPrefixCount;
    _Static_assert(sizeof(prefixes) / sizeof(prefixes[0]) == LFVideoIdPrefixCount, "prefix count out of step");
    // Measured once. The comparison below runs for every byte of every payload
    // the app builds, and calling strlen on a constant inside it would cost more
    // than the comparison itself.
    static NSUInteger prefixLengths[LFVideoIdPrefixCount];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSUInteger which = 0; which < prefixCount; which++)
            prefixLengths[which] = strlen(prefixes[which]);
    });

    for (NSUInteger index = 0; index < length; index++) {
        for (NSUInteger which = 0; which < prefixCount; which++) {
            NSUInteger prefixLength = prefixLengths[which];
            if (index + prefixLength + 11 > length)
                continue;
            if (memcmp(bytes + index, prefixes[which], prefixLength) != 0)
                continue;

            const uint8_t *identifier = bytes + index + prefixLength;
            BOOL valid = YES;
            for (NSUInteger offset = 0; offset < 11 && valid; offset++)
                valid = LFIsChannelIdCharacter(identifier[offset]);
            if (!valid)
                continue;

            return [[NSString alloc] initWithBytes:identifier length:11 encoding:NSASCIIStringEncoding];
        }
    }
    return nil;
}

NSArray<NSString *> *LFChannelIdsInData(NSData *data) {
    if (![data isKindOfClass:[NSData class]])
        return @[];
    return LFChannelIdsInBytes(data.bytes, data.length, 0);
}

#pragma mark - Field roles

static NSString *LFNormalizedKey(NSString *key) {
    NSMutableString *normalized = [NSMutableString stringWithCapacity:key.length];
    for (NSUInteger index = 0; index < key.length; index++) {
        unichar character = [key characterAtIndex:index];
        if (character == '_' || character == '-' || character == ' ')
            continue;
        [normalized appendFormat:@"%C", character];
    }
    return normalized.lowercaseString;
}

static NSString *LFVideoIdFromText(NSString *text) {
    if (text.length == 0)
        return nil;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression
            regularExpressionWithPattern:
                @"(?:[?&]v=|youtu\\.be/|/shorts/|/embed/|i\\.ytimg\\.com/vi(?:_webp)?/)([A-Za-z0-9_-]{11})(?:[^A-Za-z0-9_-]|$)"
                                 options:0
                                   error:nil];
    });

    NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (match.numberOfRanges > 1)
        return [trimmed substringWithRange:[match rangeAtIndex:1]];

    if (trimmed.length == 11) {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                       @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
        if ([trimmed rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound)
            return trimmed;
    }
    return nil;
}

static LFFieldRole LFRoleForKey(NSString *key, NSUInteger *priority) {
    NSString *normalized = LFNormalizedKey(key);

    // Channel identity first: these are the fields whitelist mode actually wants.
    if ([normalized isEqualToString:@"channelid"] || [normalized isEqualToString:@"externalchannelid"] ||
        [normalized isEqualToString:@"ownerchannelid"] || [normalized isEqualToString:@"browseid"] ||
        [normalized isEqualToString:@"ucid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"browseid"] ? 80 : 100;
        return LFFieldRoleChannelId;
    }

    if ([normalized isEqualToString:@"canonicalbaseurl"] || [normalized isEqualToString:@"channelhandle"] ||
        [normalized isEqualToString:@"handle"] || [normalized isEqualToString:@"ownerhandle"]) {
        if (priority)
            *priority = 100;
        return LFFieldRoleHandle;
    }

    if ([normalized isEqualToString:@"videoid"] || [normalized isEqualToString:@"videoidentifier"] ||
        [normalized isEqualToString:@"contentvideoid"] || [normalized isEqualToString:@"youtubevideoid"] ||
        [normalized isEqualToString:@"playerresponsevideoid"] || [normalized isEqualToString:@"watchvideoid"]) {
        if (priority)
            *priority = [normalized isEqualToString:@"videoid"] ? 100 : 90;
        return LFFieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"contentid"]) {
        if (priority)
            *priority = 85;
        return LFFieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videourl"] || [normalized isEqualToString:@"watchurl"] ||
        [normalized isEqualToString:@"webpageurl"]) {
        if (priority)
            *priority = 70;
        return LFFieldRoleVideoId;
    }

    if ([normalized isEqualToString:@"videotitle"] || [normalized isEqualToString:@"contenttitle"] ||
        [normalized isEqualToString:@"videoname"]) {
        if (priority)
            *priority = 100;
        return LFFieldRoleTitle;
    }

    if ([normalized isEqualToString:@"title"] || [normalized isEqualToString:@"headline"] ||
        [normalized isEqualToString:@"titletext"]) {
        if (priority)
            *priority = 80;
        return LFFieldRoleTitle;
    }

    if ([normalized isEqualToString:@"ownerdisplayname"] || [normalized isEqualToString:@"ownername"] ||
        [normalized isEqualToString:@"channeldisplayname"] || [normalized isEqualToString:@"authorname"]) {
        if (priority)
            *priority = 100;
        return LFFieldRoleChannel;
    }

    if ([normalized isEqualToString:@"channelname"] || [normalized isEqualToString:@"channeltitle"] ||
        [normalized isEqualToString:@"displayname"] || [normalized isEqualToString:@"channel"] ||
        [normalized isEqualToString:@"author"] || [normalized isEqualToString:@"owner"] ||
        [normalized isEqualToString:@"bylinetext"] || [normalized isEqualToString:@"shortbylinetext"] ||
        [normalized isEqualToString:@"longbylinetext"]) {
        if (priority)
            *priority = 80;
        return LFFieldRoleChannel;
    }

    if (priority)
        *priority = 0;
    return LFFieldRoleNone;
}

// Text that YouTube renders in a channel slot but which identifies nothing.
static BOOL LFIsSyntheticChannelValue(NSString *text) {
    NSString *normalized =
        [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    static NSSet<NSString *> *synthetic;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        synthetic = [NSSet setWithArray:@[
            @"action menu", @"more actions", @"live", @"sponsored", @"verified", @"premiere", @"ad", @"new",
            @"members only", @"shorts"
        ]];
    });
    return normalized.length == 0 || [synthetic containsObject:normalized];
}

static NSString *LFResultKeyForRole(LFFieldRole role) {
    switch (role) {
        case LFFieldRoleVideoId:
            return LFInfoVideoIdKey;
        case LFFieldRoleTitle:
            return LFInfoTitleKey;
        case LFFieldRoleChannel:
            return LFInfoChannelKey;
        case LFFieldRoleChannelId:
            return LFInfoChannelIdKey;
        case LFFieldRoleHandle:
            return LFInfoHandleKey;
        case LFFieldRoleNone:
            break;
    }
    return nil;
}

static void LFRecordValue(NSMutableDictionary *result, NSMutableDictionary *priorities, LFFieldRole role,
                          NSUInteger priority, id value) {
    NSString *resultKey = LFResultKeyForRole(role);
    if (!resultKey)
        return;

    NSString *text = LFTextFromValue(value);
    if (text.length == 0)
        return;

    switch (role) {
        case LFFieldRoleVideoId:
            text = LFVideoIdFromText(text);
            break;
        case LFFieldRoleChannelId:
            text = LFNormalizeChannelId(text);
            break;
        case LFFieldRoleHandle:
            text = LFNormalizeHandle(text);
            break;
        case LFFieldRoleChannel:
            if (LFIsSyntheticChannelValue(text))
                return;
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        default:
            break;
    }
    if (text.length == 0)
        return;

    NSUInteger previous = [priorities[resultKey] unsignedIntegerValue];
    if ([(NSString *)result[resultKey] length] == 0 || priority > previous) {
        result[resultKey] = text;
        priorities[resultKey] = @(priority);
    }
}

static void LFRecordField(NSMutableDictionary *result, NSMutableDictionary *priorities, NSString *key, id value) {
    NSUInteger priority = 0;
    LFFieldRole role = LFRoleForKey(key, &priority);
    if (role == LFFieldRoleNone)
        return;
    LFRecordValue(result, priorities, role, priority, value);

    // A "browseId"/"canonicalBaseUrl" style field often carries both forms.
    if (role == LFFieldRoleChannelId || role == LFFieldRoleHandle) {
        NSString *text = LFTextFromValue(value);
        if (text.length > 0) {
            LFRecordValue(result, priorities, LFFieldRoleChannelId, priority > 10 ? priority - 10 : 1, text);
            LFRecordValue(result, priorities, LFFieldRoleHandle, priority > 10 ? priority - 10 : 1, text);
        }
    }
}

#pragma mark - Element renderer payloads

static BOOL LFReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *value) {
    uint64_t result = 0;
    for (NSUInteger shift = 0; *offset < length && shift <= 63; shift += 7) {
        uint8_t byte = bytes[(*offset)++];
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static BOOL LFIsPrintableUTF8(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length == 0 || length > 4096)
        return NO;

    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (text.length == 0)
        return NO;

    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < 0x20 && character != '\n' && character != '\r' && character != '\t')
            return NO;
    }
    return YES;
}

// Walks a protobuf payload recursively. Fields 36/37 of YouTube's element
// renderer payload are the video title and the channel display name; this
// mapping is Gonerino's finding and is the one piece of field numbering the
// implementation depends on. Everything else is recovered by pattern, so a
// renumbering degrades the result rather than breaking it.
static void LFRecordElementRendererFields(const uint8_t *bytes, NSUInteger length, NSMutableDictionary *result,
                                          NSMutableDictionary *priorities, NSUInteger depth) {
    if (!bytes || length == 0 || depth > 8)
        return;

    NSUInteger offset = 0;
    while (offset < length) {
        uint64_t tag = 0;
        if (!LFReadVarint(bytes, length, &offset, &tag))
            return;

        uint64_t fieldNumber = tag >> 3;
        uint64_t wireType = tag & 7;
        if (fieldNumber == 0)
            return;

        if (wireType == 0) {
            uint64_t ignored = 0;
            if (!LFReadVarint(bytes, length, &offset, &ignored))
                return;
            continue;
        }
        if (wireType == 1) {
            if (length - offset < 8)
                return;
            offset += 8;
            continue;
        }
        if (wireType == 5) {
            if (length - offset < 4)
                return;
            offset += 4;
            continue;
        }
        if (wireType != 2)
            return;

        uint64_t valueLength = 0;
        if (!LFReadVarint(bytes, length, &offset, &valueLength) || valueLength > length - offset)
            return;

        const uint8_t *valueBytes = bytes + offset;
        NSUInteger valueSize = (NSUInteger)valueLength;
        BOOL printable = LFIsPrintableUTF8(valueBytes, valueSize);

        if (printable) {
            NSString *text = [[NSString alloc] initWithBytes:valueBytes length:valueSize encoding:NSUTF8StringEncoding];
            if (fieldNumber == 36)
                LFRecordValue(result, priorities, LFFieldRoleTitle, 95, text);
            else if (fieldNumber == 37)
                LFRecordValue(result, priorities, LFFieldRoleChannel, 95, text);
        } else {
            LFRecordElementRendererFields(valueBytes, valueSize, result, priorities, depth + 1);
        }
        offset += valueSize;
    }
}

NSDictionary<NSString *, NSString *> *LFVideoInfoFromElementData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionary];

    @try {
        const uint8_t *bytes = data.bytes;
        NSUInteger length = MIN(data.length, (NSUInteger)262144);
        LFRecordElementRendererFields(bytes, length, result, priorities, 0);

        // The owner's channel id and handle are carried by the cell's navigation
        // endpoints. A video cell references exactly one channel, so the first
        // match is the right one; where several appear they are the same channel
        // in different forms (browse endpoint, canonical URL, avatar link).
        NSString *channelId = LFChannelIdsInBytes(bytes, length, 1).firstObject;
        if (channelId)
            LFRecordValue(result, priorities, LFFieldRoleChannelId, 90, channelId);

        NSString *handle = LFHandlesInBytes(bytes, length, 1).firstObject;
        if (handle)
            LFRecordValue(result, priorities, LFFieldRoleHandle, 90, handle);

        NSString *videoId = LFVideoIdInBytes(bytes, length);
        if (videoId)
            LFRecordValue(result, priorities, LFFieldRoleVideoId, 60, videoId);
    } @catch (__unused NSException *exception) {
        return nil;
    }

    return result.count > 0 ? [result copy] : nil;
}

#pragma mark - Node traversal

static NSArray<NSString *> *LFFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"channelId", @"channelID", @"externalChannelId", @"ownerChannelId", @"browseId", @"ucid",
            @"canonicalBaseUrl", @"channelHandle", @"handle", @"ownerHandle",
            @"videoId", @"videoID", @"contentVideoId", @"contentVideoID", @"videoURL", @"watchURL",
            @"videoTitle", @"contentTitle", @"title", @"headline",
            @"ownerDisplayName", @"ownerName", @"channelDisplayName", @"authorName", @"channelName",
            @"channelTitle", @"author", @"owner", @"shortBylineText", @"longBylineText", @"bylineText"
        ];
    });
    return keys;
}

static NSArray<NSString *> *LFChildKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"node", @"cellNode", @"contentNode", @"videoNode", @"metadataNode", @"model", @"entry", @"element",
            @"elementEntry", @"renderer", @"videoRenderer", @"content", @"data", @"controller", @"owningComponent",
            @"parentResponder", @"navigationEndpoint", @"browseEndpoint", @"videoDetails", @"playerResponse",
            @"singleVideo", @"currentVideo", @"videoData", @"reelModel", @"contentModel", @"reelWatchEndpoint",
            @"materializedInstance"
        ];
    });
    return keys;
}

static BOOL LFShouldVisitKey(NSString *key) {
    NSString *normalized = LFNormalizedKey(key);
    // Cheap guard against walking into the whole view hierarchy or into config
    // objects; those are large and never carry the owner's identity.
    return ![normalized isEqualToString:@"superview"] && ![normalized isEqualToString:@"window"] &&
           ![normalized isEqualToString:@"layer"] && ![normalized isEqualToString:@"nextresponder"];
}

static void LFCollectObject(id object, NSMutableDictionary *result, NSMutableDictionary *priorities,
                            NSMutableSet *visited, NSUInteger *budget, NSUInteger depth) {
    if (!object || depth > 6 || *budget == 0)
        return;

    NSValue *identity = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:identity])
        return;
    [visited addObject:identity];
    (*budget)--;

    @try {
        for (NSString *key in LFFieldKeys())
            LFRecordField(result, priorities, key, LFValueForKey(object, key));

        // An element renderer's opaque payload.
        for (NSString *dataKey in @[@"elementData", @"data"]) {
            id data = LFValueForKey(object, dataKey);
            if ([data isKindOfClass:[NSData class]]) {
                NSDictionary *info = LFVideoInfoFromElementData(data);
                if (info[LFInfoChannelIdKey])
                    LFRecordValue(result, priorities, LFFieldRoleChannelId, 88, info[LFInfoChannelIdKey]);
                if (info[LFInfoHandleKey])
                    LFRecordValue(result, priorities, LFFieldRoleHandle, 88, info[LFInfoHandleKey]);
                if (info[LFInfoChannelKey])
                    LFRecordValue(result, priorities, LFFieldRoleChannel, 88, info[LFInfoChannelKey]);
                if (info[LFInfoTitleKey])
                    LFRecordValue(result, priorities, LFFieldRoleTitle, 88, info[LFInfoTitleKey]);
                if (info[LFInfoVideoIdKey])
                    LFRecordValue(result, priorities, LFFieldRoleVideoId, 55, info[LFInfoVideoIdKey]);
            }
        }

        for (NSString *key in LFChildKeys()) {
            if (!LFShouldVisitKey(key))
                continue;
            id child = LFValueForKey(object, key);
            if (child && child != object)
                LFCollectObject(child, result, priorities, visited, budget, depth + 1);
        }

        for (NSString *key in @[@"subnodes", @"children", @"contents", @"itemsArray", @"contentsArray"]) {
            id collection = LFValueForKey(object, key);
            if (![collection isKindOfClass:[NSArray class]])
                continue;
            for (id child in (NSArray *)collection) {
                if (*budget == 0)
                    break;
                LFCollectObject(child, result, priorities, visited, budget, depth + 1);
            }
        }
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - Rendered-text fallback

static NSString *LFTextForNode(id node) {
    id attributed = LFValueForKey(node, @"attributedText");
    if ([attributed isKindOfClass:[NSAttributedString class]])
        return ((NSAttributedString *)attributed).string;
    id label = LFValueForKey(node, @"accessibilityLabel");
    return [label isKindOfClass:[NSString class]] ? label : nil;
}

// Heuristic borrowed from Gonerino: in cells that expose nothing but rendered
// text, the channel line is a short run that is not the title and carries none
// of the metadata decorations ("1.2M views", "3 days ago", durations).
static BOOL LFIsLikelyChannelText(NSString *text, NSString *title) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || trimmed.length > 60)
        return NO;
    if (LFIsSyntheticChannelValue(trimmed))
        return NO;
    if (title.length > 0 && ([trimmed isEqualToString:title] ||
                             [title.lowercaseString containsString:trimmed.lowercaseString]))
        return NO;

    NSString *lowercase = trimmed.lowercaseString;
    for (NSString *marker in @[@" views", @" view", @"watching", @" ago", @"subscriber", @"回視聴", @"前", @"登録者"]) {
        if ([lowercase containsString:marker])
            return NO;
    }
    // Durations such as "12:34".
    if ([trimmed rangeOfString:@":"].location != NSNotFound &&
        [trimmed rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound)
        return NO;

    return YES;
}

static void LFCollectTextNodes(id node, NSMutableArray<NSString *> *texts, NSUInteger depth, NSUInteger *budget) {
    if (!node || depth > 8 || *budget == 0)
        return;
    (*budget)--;

    NSString *text = LFTextForNode(node);
    if (text.length > 0)
        [texts addObject:text];

    id subnodes = LFValueForKey(node, @"subnodes");
    if ([subnodes isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)subnodes) {
            if (*budget == 0)
                break;
            LFCollectTextNodes(child, texts, depth + 1, budget);
        }
    }
}

static NSString *LFChannelTextFromNode(id node, NSString *title) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSUInteger budget = 64;
    LFCollectTextNodes(node, texts, 0, &budget);

    for (NSString *text in texts) {
        // A rendered channel line is sometimes "Channel • 1.2M views • 2 days ago".
        NSString *candidate = [text componentsSeparatedByString:@"•"].firstObject ?: text;
        candidate = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (LFIsLikelyChannelText(candidate, title))
            return candidate;
    }
    return nil;
}

#pragma mark - Cache

static NSMapTable *LFMetadataCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

// Nodes are recycled and populated asynchronously, so an incomplete reading is
// remembered only briefly and then retried.
static NSMapTable *LFPendingCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

static BOOL LFMetadataIsComplete(NSDictionary *info) {
    // "Complete" for whitelist purposes means the channel is identified.
    return info[LFInfoChannelIdKey] != nil || info[LFInfoHandleKey] != nil || info[LFInfoChannelKey] != nil;
}

static NSDictionary *LFVideoInfoFromNodeInternal(id node, BOOL bypassCache) {
    if (!node)
        return nil;

    if (!bypassCache) {
        NSDictionary *cached = [LFMetadataCache() objectForKey:node];
        if (cached)
            return cached;

        NSDictionary *pending = [LFPendingCache() objectForKey:node];
        NSNumber *timestamp = pending[@"timestamp"];
        if (timestamp && NSDate.timeIntervalSinceReferenceDate - timestamp.doubleValue < 0.75)
            return pending[@"metadata"];
        if (pending)
            [LFPendingCache() removeObjectForKey:node];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *priorities = [NSMutableDictionary dictionary];

    @try {
        NSUInteger budget = 64;
        NSMutableSet *visited = [NSMutableSet set];
        LFCollectObject(node, result, priorities, visited, &budget, 0);

        // Cells whose controller owns the element entry keep the payload one hop
        // away from the node itself.
        id elementEntry = LFValueForKey(LFValueForKey(node, @"parentResponder"), @"elementEntry");
        if (elementEntry) {
            NSUInteger entryBudget = 24;
            LFCollectObject(elementEntry, result, priorities, visited, &entryBudget, 0);
        }

        if ([(NSString *)result[LFInfoChannelKey] length] == 0) {
            NSString *channel = LFChannelTextFromNode(node, result[LFInfoTitleKey]);
            if (channel)
                LFRecordValue(result, priorities, LFFieldRoleChannel, 40, channel);
        }

        // A channel line that merely repeats the title is not an identity.
        NSString *title = result[LFInfoTitleKey];
        NSString *channel = result[LFInfoChannelKey];
        if (title.length > 0 && channel.length > 0 && [channel caseInsensitiveCompare:title] == NSOrderedSame) {
            [result removeObjectForKey:LFInfoChannelKey];
            [priorities removeObjectForKey:LFInfoChannelKey];
        }
    } @catch (__unused NSException *exception) {
    }

    if (result.count == 0) {
        if (!bypassCache)
            [LFPendingCache() setObject:@{@"metadata": @{}, @"timestamp": @(NSDate.timeIntervalSinceReferenceDate)} forKey:node];
        return nil;
    }

    NSDictionary *metadata = [result copy];
    if (LFMetadataIsComplete(metadata)) {
        [LFMetadataCache() setObject:metadata forKey:node];
        [LFPendingCache() removeObjectForKey:node];
    } else if (!bypassCache) {
        [LFPendingCache() setObject:@{@"metadata": metadata, @"timestamp": @(NSDate.timeIntervalSinceReferenceDate)} forKey:node];
    }
    return metadata;
}

NSDictionary<NSString *, NSString *> *LFVideoInfoFromNode(id node) {
    return LFVideoInfoFromNodeInternal(node, NO);
}

NSDictionary<NSString *, NSString *> *LFFreshVideoInfoFromNode(id node) {
    if (!node)
        return nil;
    [LFPendingCache() removeObjectForKey:node];
    [LFMetadataCache() removeObjectForKey:node];
    return LFVideoInfoFromNodeInternal(node, YES);
}
