// Learning Filter — the whitelist.
//
// "Whitelist" here is not a hand-authored list: it is the set of channels the
// signed-in YouTube account is subscribed to. The store is a cache of what has
// been harvested from YouTube's own data so that a decision can be made
// synchronously while a feed is being laid out.
//
// Three parallel identity sets are kept, because different surfaces expose
// different identifiers for the same channel:
//   - channel ids   (UCxxxxxxxxxxxxxxxxxxxxxx)   most reliable
//   - handles       (@example)                   stable, shown in newer cells
//   - display names ("Example Channel")          the only thing many cells carry
//
// They are deliberately *not* paired: a feed item matches if any identifier it
// exposes is in the corresponding set.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFSubscriptionStore : NSObject

+ (instancetype)sharedInstance;

#pragma mark - Reading

@property(nonatomic, readonly) NSArray<NSString *> *subscribedChannelIds;
@property(nonatomic, readonly) NSArray<NSString *> *subscribedHandles;
// Display names, sorted, including manual additions.
@property(nonatomic, readonly) NSArray<NSString *> *subscribedNames;
@property(nonatomic, readonly) NSArray<NSString *> *manualNames;
@property(nonatomic, readonly) NSDate *_Nullable lastSyncDate;

// YES when nothing has been harvested yet (signed out, or first launch).
// Whitelist filtering stays inert in that state — see requirement 9.
@property(nonatomic, readonly, getter=isEmpty) BOOL empty;

// Bumped on every change. Callers that cache a decision derived from the
// whitelist compare against this to know when their cache went stale.
@property(nonatomic, readonly) NSUInteger generation;

- (BOOL)isSubscribedToChannelId:(nullable NSString *)channelId;
- (BOOL)isSubscribedToHandle:(nullable NSString *)handle;
- (BOOL)isSubscribedToChannelName:(nullable NSString *)channelName;

#pragma mark - Harvesting

// Records one subscribed channel. Any subset of the three identifiers may be nil.
// Returns YES when this call added something new.
- (BOOL)recordSubscribedChannelId:(nullable NSString *)channelId
                           handle:(nullable NSString *)handle
                             name:(nullable NSString *)name;

// Bulk harvest from one response. Replaces nothing; the store only grows, so a
// partially-loaded guide never shrinks the whitelist mid-session.
- (BOOL)recordSubscribedChannelIds:(nullable NSArray<NSString *> *)channelIds
                           handles:(nullable NSArray<NSString *> *)handles
                             names:(nullable NSArray<NSString *> *)names;

// Called when YouTube reports that the account unsubscribed from a channel, so
// the whitelist tracks the account rather than drifting.
- (void)forgetChannelId:(nullable NSString *)channelId
                 handle:(nullable NSString *)handle
                   name:(nullable NSString *)name;

#pragma mark - Manual overrides (escape hatch, secondary to harvesting)

- (void)addManualName:(NSString *)name;
- (void)removeManualName:(NSString *)name;

#pragma mark - Maintenance

// Drops everything harvested. Used when the account is signed out or the user
// asks for a fresh sync.
- (void)reset;

@end

#pragma mark - Identity normalisation

// "UCxxxx" when the string is (or contains) a channel id, else nil.
FOUNDATION_EXPORT NSString *_Nullable LFNormalizeChannelId(NSString *_Nullable value);
// "@handle" lowercased when the string is (or contains) a handle, else nil.
FOUNDATION_EXPORT NSString *_Nullable LFNormalizeHandle(NSString *_Nullable value);
// Case/whitespace folded display name, else nil.
FOUNDATION_EXPORT NSString *_Nullable LFNormalizeChannelName(NSString *_Nullable value);

NS_ASSUME_NONNULL_END
