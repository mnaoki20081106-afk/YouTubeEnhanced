#import "LFSubscriptionStore.h"
#import "LFCommon.h"

#pragma mark - Identity normalisation

NSString *LFNormalizeChannelId(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length < 24)
        return nil;

    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // A YouTube channel id is "UC" followed by 22 base64url characters.
        regex = [NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}" options:0 error:nil];
    });

    NSTextCheckingResult *match = [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match)
        return nil;

    NSString *channelId = [value substringWithRange:match.range];
    // Guard against a longer base64url run that merely starts with "UC".
    NSUInteger end = NSMaxRange(match.range);
    if (end < value.length) {
        unichar next = [value characterAtIndex:end];
        if ((next >= 'A' && next <= 'Z') || (next >= 'a' && next <= 'z') || (next >= '0' && next <= '9') ||
            next == '_' || next == '-')
            return nil;
    }
    return channelId;
}

NSString *LFNormalizeHandle(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length < 4)
        return nil;

    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Only accept a handle where YouTube actually writes one: at the start of the
    // string, or as a "/@name" path component. A stray "@" inside a video title
    // must not be mistaken for a channel identity.
    NSRange atRange = NSMakeRange(NSNotFound, 0);
    if ([trimmed hasPrefix:@"@"])
        atRange = NSMakeRange(0, 1);
    else {
        NSRange slashAt = [trimmed rangeOfString:@"/@"];
        if (slashAt.location != NSNotFound)
            atRange = NSMakeRange(slashAt.location + 1, 1);
    }
    if (atRange.location == NSNotFound)
        return nil;

    NSUInteger start = NSMaxRange(atRange);
    NSMutableString *handle = [NSMutableString stringWithString:@"@"];
    for (NSUInteger index = start; index < trimmed.length; index++) {
        unichar character = [trimmed characterAtIndex:index];
        BOOL allowed = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
                       (character >= '0' && character <= '9') || character == '.' || character == '_' ||
                       character == '-';
        if (!allowed)
            break;
        [handle appendFormat:@"%C", character];
    }

    // YouTube handles are 3-30 characters after the "@".
    if (handle.length < 4 || handle.length > 31)
        return nil;
    return handle.lowercaseString;
}

NSString *LFNormalizeChannelName(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0)
        return nil;

    NSMutableString *cleaned = [value mutableCopy];
    // Verified badges and invisible marks travel with the rendered channel text.
    for (NSString *decoration in @[@"✓", @"✔", @"​", @"‌", @"‍", @"﻿"])
        [cleaned replaceOccurrencesOfString:decoration
                                 withString:@""
                                    options:0
                                      range:NSMakeRange(0, cleaned.length)];

    NSArray<NSString *> *words = [cleaned componentsSeparatedByCharactersInSet:
                                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *word in words) {
        if (word.length > 0)
            [kept addObject:word];
    }

    NSString *normalized = [[kept componentsJoinedByString:@" "] lowercaseString];
    return normalized.length > 0 ? normalized : nil;
}

#pragma mark - Store

@interface LFSubscriptionStore ()
@property(nonatomic, strong) NSMutableSet<NSString *> *channelIdSet;
@property(nonatomic, strong) NSMutableSet<NSString *> *handleSet;
// Normalised names -> the display form last seen, so settings can show something readable.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nameMap;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *manualNameMap;
@property(nonatomic, assign) NSUInteger generation;
@end

@implementation LFSubscriptionStore

+ (instancetype)sharedInstance {
    static LFSubscriptionStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _channelIdSet = [NSMutableSet set];
        _handleSet = [NSMutableSet set];
        _nameMap = [NSMutableDictionary dictionary];
        _manualNameMap = [NSMutableDictionary dictionary];

        for (id value in [defaults arrayForKey:LFSubscribedChannelIdsKey]) {
            NSString *channelId = LFNormalizeChannelId(value);
            if (channelId)
                [_channelIdSet addObject:channelId];
        }
        for (id value in [defaults arrayForKey:LFSubscribedHandlesKey]) {
            NSString *handle = LFNormalizeHandle(value);
            if (handle)
                [_handleSet addObject:handle];
        }
        for (id value in [defaults arrayForKey:LFSubscribedNamesKey]) {
            NSString *normalized = LFNormalizeChannelName(value);
            if (normalized)
                _nameMap[normalized] = value;
        }
        for (id value in [defaults arrayForKey:LFManualNamesKey]) {
            NSString *normalized = LFNormalizeChannelName(value);
            if (normalized)
                _manualNameMap[normalized] = value;
        }
    }
    return self;
}

#pragma mark - Reading

- (NSArray<NSString *> *)subscribedChannelIds {
    @synchronized(self) {
        return [self.channelIdSet.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NSArray<NSString *> *)subscribedHandles {
    @synchronized(self) {
        return [self.handleSet.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NSArray<NSString *> *)subscribedNames {
    @synchronized(self) {
        NSMutableArray<NSString *> *names = [self.nameMap.allValues mutableCopy];
        [names addObjectsFromArray:self.manualNameMap.allValues];
        return [names sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }
}

- (NSArray<NSString *> *)manualNames {
    @synchronized(self) {
        return [self.manualNameMap.allValues sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }
}

- (NSDate *)lastSyncDate {
    NSTimeInterval stamp = [[NSUserDefaults standardUserDefaults] doubleForKey:LFLastSyncKey];
    return stamp > 0 ? [NSDate dateWithTimeIntervalSince1970:stamp] : nil;
}

- (BOOL)isEmpty {
    @synchronized(self) {
        return self.channelIdSet.count == 0 && self.handleSet.count == 0 && self.nameMap.count == 0 &&
               self.manualNameMap.count == 0;
    }
}

- (BOOL)isSubscribedToChannelId:(NSString *)channelId {
    NSString *normalized = LFNormalizeChannelId(channelId);
    if (!normalized)
        return NO;
    @synchronized(self) {
        return [self.channelIdSet containsObject:normalized];
    }
}

- (BOOL)isSubscribedToHandle:(NSString *)handle {
    NSString *normalized = LFNormalizeHandle(handle);
    if (!normalized)
        return NO;
    @synchronized(self) {
        return [self.handleSet containsObject:normalized];
    }
}

- (BOOL)isSubscribedToChannelName:(NSString *)channelName {
    NSString *normalized = LFNormalizeChannelName(channelName);
    if (!normalized)
        return NO;
    @synchronized(self) {
        return self.nameMap[normalized] != nil || self.manualNameMap[normalized] != nil;
    }
}

#pragma mark - Harvesting

- (BOOL)recordSubscribedChannelId:(NSString *)channelId handle:(NSString *)handle name:(NSString *)name {
    BOOL changed = NO;
    @synchronized(self) {
        NSString *normalizedId = LFNormalizeChannelId(channelId);
        if (normalizedId && ![self.channelIdSet containsObject:normalizedId]) {
            [self.channelIdSet addObject:normalizedId];
            changed = YES;
        }

        NSString *normalizedHandle = LFNormalizeHandle(handle);
        if (normalizedHandle && ![self.handleSet containsObject:normalizedHandle]) {
            [self.handleSet addObject:normalizedHandle];
            changed = YES;
        }

        NSString *normalizedName = LFNormalizeChannelName(name);
        if (normalizedName && self.nameMap[normalizedName] == nil) {
            self.nameMap[normalizedName] = name;
            changed = YES;
        }
    }

    if (changed)
        [self persist];
    return changed;
}

- (BOOL)recordSubscribedChannelIds:(NSArray<NSString *> *)channelIds
                           handles:(NSArray<NSString *> *)handles
                             names:(NSArray<NSString *> *)names {
    BOOL changed = NO;
    @synchronized(self) {
        for (NSString *value in channelIds) {
            NSString *normalized = LFNormalizeChannelId(value);
            if (normalized && ![self.channelIdSet containsObject:normalized]) {
                [self.channelIdSet addObject:normalized];
                changed = YES;
            }
        }
        for (NSString *value in handles) {
            NSString *normalized = LFNormalizeHandle(value);
            if (normalized && ![self.handleSet containsObject:normalized]) {
                [self.handleSet addObject:normalized];
                changed = YES;
            }
        }
        for (NSString *value in names) {
            NSString *normalized = LFNormalizeChannelName(value);
            if (normalized && self.nameMap[normalized] == nil) {
                self.nameMap[normalized] = value;
                changed = YES;
            }
        }
    }

    if (changed)
        [self persist];
    return changed;
}

- (void)forgetChannelId:(NSString *)channelId handle:(NSString *)handle name:(NSString *)name {
    BOOL changed = NO;
    @synchronized(self) {
        NSString *normalizedId = LFNormalizeChannelId(channelId);
        if (normalizedId && [self.channelIdSet containsObject:normalizedId]) {
            [self.channelIdSet removeObject:normalizedId];
            changed = YES;
        }

        NSString *normalizedHandle = LFNormalizeHandle(handle);
        if (normalizedHandle && [self.handleSet containsObject:normalizedHandle]) {
            [self.handleSet removeObject:normalizedHandle];
            changed = YES;
        }

        NSString *normalizedName = LFNormalizeChannelName(name);
        if (normalizedName && self.nameMap[normalizedName] != nil) {
            [self.nameMap removeObjectForKey:normalizedName];
            changed = YES;
        }
    }

    if (changed)
        [self persist];
}

#pragma mark - Manual overrides

- (void)addManualName:(NSString *)name {
    NSString *normalized = LFNormalizeChannelName(name);
    if (!normalized)
        return;
    @synchronized(self) {
        self.manualNameMap[normalized] =
            [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    [self persist];
}

- (void)removeManualName:(NSString *)name {
    NSString *normalized = LFNormalizeChannelName(name);
    if (!normalized)
        return;
    @synchronized(self) {
        [self.manualNameMap removeObjectForKey:normalized];
    }
    [self persist];
}

#pragma mark - Maintenance

- (void)reset {
    @synchronized(self) {
        [self.channelIdSet removeAllObjects];
        [self.handleSet removeAllObjects];
        [self.nameMap removeAllObjects];
    }
    [self persist];
}

- (void)persist {
    @synchronized(self) {
        self.generation++;
    }

    NSArray<NSString *> *channelIds = nil;
    NSArray<NSString *> *handles = nil;
    NSArray<NSString *> *names = nil;
    NSArray<NSString *> *manual = nil;
    @synchronized(self) {
        channelIds = self.channelIdSet.allObjects;
        handles = self.handleSet.allObjects;
        names = self.nameMap.allValues;
        manual = self.manualNameMap.allValues;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:channelIds forKey:LFSubscribedChannelIdsKey];
    [defaults setObject:handles forKey:LFSubscribedHandlesKey];
    [defaults setObject:names forKey:LFSubscribedNamesKey];
    [defaults setObject:manual forKey:LFManualNamesKey];
    [defaults setDouble:[[NSDate date] timeIntervalSince1970] forKey:LFLastSyncKey];
    [defaults synchronize];
}

@end
