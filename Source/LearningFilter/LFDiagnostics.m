#import "LFDiagnostics.h"
#import "LFCommon.h"
#import "LFMetadata.h"

static const NSUInteger LFDiagnosticsCapacity = 60;

static NSString *LFSurfaceName(LFSurface surface) {
    switch (surface) {
        case LFSurfaceHome:
            return @"home";
        case LFSurfaceSearch:
            return @"search";
        case LFSurfaceShorts:
            return @"shorts";
        case LFSurfaceRelated:
            return @"related";
        case LFSurfaceOther:
            return @"other";
    }
    return @"other";
}

static NSString *LFDecisionName(LFDecision decision) {
    switch (decision) {
        case LFDecisionAllow:
            return @"allow";
        case LFDecisionHide:
            return @"hide";
        case LFDecisionUnknown:
            return @"unknown";
    }
    return @"unknown";
}

@implementation LFDiagnosticsEntry

- (NSString *)summary {
    NSString *who = self.channelName.length > 0 ? self.channelName
                    : self.handle.length > 0    ? self.handle
                    : self.channelId.length > 0 ? self.channelId
                                                : @"(no channel identity)";
    return [NSString stringWithFormat:@"%@ %@ — %@", self.hidden ? @"HIDDEN" : @"shown", self.decision, who];
}

- (NSString *)detail {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@/%@", self.source, self.surface]];
    if (self.channelId.length > 0)
        [parts addObject:[NSString stringWithFormat:@"id %@", self.channelId]];
    else
        [parts addObject:@"id —"];
    if (self.handle.length > 0)
        [parts addObject:self.handle];
    if (self.videoId.length > 0)
        [parts addObject:[NSString stringWithFormat:@"video %@", self.videoId]];
    return [parts componentsJoinedByString:@" · "];
}

@end

@interface LFDiagnostics ()
@property(nonatomic, strong) NSMutableArray<LFDiagnosticsEntry *> *buffer;
@property(nonatomic, assign) NSUInteger allowCount;
@property(nonatomic, assign) NSUInteger hideCount;
@property(nonatomic, assign) NSUInteger unknownCount;
@property(nonatomic, assign) NSUInteger skippedCount;
@end

@implementation LFDiagnostics

+ (instancetype)sharedInstance {
    static LFDiagnostics *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self)
        _buffer = [NSMutableArray arrayWithCapacity:LFDiagnosticsCapacity];
    return self;
}

- (NSArray<LFDiagnosticsEntry *> *)entries {
    @synchronized(self) {
        return [[self.buffer reverseObjectEnumerator] allObjects];
    }
}

- (void)recordSource:(NSString *)source
             surface:(LFSurface)surface
                info:(NSDictionary<NSString *, NSString *> *)info
            decision:(LFDecision)decision
              hidden:(BOOL)hidden {
    if (!LFDiagnosticsEnabled())
        return;

    LFDiagnosticsEntry *entry = [[LFDiagnosticsEntry alloc] init];
    entry.source = source;
    entry.surface = LFSurfaceName(surface);
    entry.videoId = info[LFInfoVideoIdKey];
    entry.channelId = info[LFInfoChannelIdKey];
    entry.handle = info[LFInfoHandleKey];
    entry.channelName = info[LFInfoChannelKey];
    entry.decision = LFDecisionName(decision);
    entry.hidden = hidden;
    entry.date = [NSDate date];

    @synchronized(self) {
        // Counters cover the whole session; the buffer keeps only the tail, which
        // is what is useful when something has just gone wrong on screen.
        switch (decision) {
            case LFDecisionAllow:
                self.allowCount++;
                break;
            case LFDecisionHide:
                self.hideCount++;
                break;
            case LFDecisionUnknown:
                self.unknownCount++;
                break;
        }

        [self.buffer addObject:entry];
        while (self.buffer.count > LFDiagnosticsCapacity)
            [self.buffer removeObjectAtIndex:0];
    }
}

- (void)recordSkipped {
    if (!LFDiagnosticsEnabled())
        return;
    @synchronized(self) {
        self.skippedCount++;
    }
}

- (void)reset {
    @synchronized(self) {
        [self.buffer removeAllObjects];
        self.allowCount = 0;
        self.hideCount = 0;
        self.unknownCount = 0;
        self.skippedCount = 0;
    }
}

@end
