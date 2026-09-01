// Learning Filter — channel identity extraction.
//
// Adapted from Gonerino's Util.m (github.com/castdrian/Gonerino, MIT), which
// solves the same underlying problem: YouTube's iOS feeds are built from
// AsyncDisplayKit nodes wrapping opaque "element renderer" protobufs, and the
// channel a cell belongs to is spread across whichever of those layers the
// current cell template happens to use.
//
// Gonerino only needs the channel *display name* (it blocks by name). Whitelist
// mode wants a stronger identity, so this version additionally extracts the
// channel id (UC...) and the handle (@name) wherever YouTube exposes them.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys used in the returned dictionaries.
FOUNDATION_EXPORT NSString *const LFInfoVideoIdKey;    // @"id"
FOUNDATION_EXPORT NSString *const LFInfoTitleKey;      // @"title"
FOUNDATION_EXPORT NSString *const LFInfoChannelKey;    // @"channel"    display name
FOUNDATION_EXPORT NSString *const LFInfoChannelIdKey;  // @"channelId"  UC...
FOUNDATION_EXPORT NSString *const LFInfoHandleKey;     // @"handle"     @name

// Metadata for one feed cell node (an ASDisplayNode / ELMCellNode / video node).
// Cached per node; nodes are recycled, so the cache is keyed weakly and entries
// that are not yet complete expire quickly.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *_Nullable LFVideoInfoFromNode(id _Nullable node);

// Same, bypassing the cache. Use when acting on a user gesture.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *_Nullable LFFreshVideoInfoFromNode(id _Nullable node);

// Metadata carried by a YTIElementRenderer payload, before any node exists.
// This is what lets a cell be dropped before it is ever laid out.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *_Nullable LFVideoInfoFromElementData(NSData *_Nullable data);

// Every channel id / handle appearing in a blob. Used to harvest the whitelist
// out of guide and subscription-feed responses.
FOUNDATION_EXPORT NSArray<NSString *> *LFChannelIdsInString(NSString *_Nullable text);
FOUNDATION_EXPORT NSArray<NSString *> *LFHandlesInString(NSString *_Nullable text);
FOUNDATION_EXPORT NSArray<NSString *> *LFChannelIdsInData(NSData *_Nullable data);

// Safe "call this getter if it exists and returns an object" helper.
FOUNDATION_EXPORT id _Nullable LFValueForKey(id _Nullable object, NSString *key);

// Plain text out of an NSString / NSAttributedString / YTIFormattedString.
FOUNDATION_EXPORT NSString *_Nullable LFTextFromValue(id _Nullable value);

NS_ASSUME_NONNULL_END
