// Learning Filter — what the filter saw.
//
// Building this tweak means producing an IPA, so a blind guess costs a full
// build cycle. Every decision the filter makes is therefore recorded into a
// small ring buffer that the settings screen can show: for each item, which
// identifiers were recovered from it, which surface it was on, and what was
// decided. If the feed comes back empty or unfiltered, that screen says why
// without another build.
//
// Paired with dry-run mode, which records decisions but hides nothing, the first
// install can be used to confirm that channel identity is being extracted
// correctly before anything is actually hidden.

#import <Foundation/Foundation.h>

#import "LFCommon.h"
#import "LFFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface LFDiagnosticsEntry : NSObject
@property(nonatomic, copy) NSString *source;   // "renderer" or "cell"
@property(nonatomic, copy) NSString *surface;
@property(nonatomic, copy, nullable) NSString *videoId;
@property(nonatomic, copy, nullable) NSString *channelId;
@property(nonatomic, copy, nullable) NSString *handle;
@property(nonatomic, copy, nullable) NSString *channelName;
@property(nonatomic, copy) NSString *decision;  // "allow" / "hide" / "unknown"
@property(nonatomic, assign) BOOL hidden;       // what actually happened
@property(nonatomic, strong) NSDate *date;

// One line for the settings list.
- (NSString *)summary;
- (NSString *)detail;
@end

@interface LFDiagnostics : NSObject

+ (instancetype)sharedInstance;

@property(nonatomic, readonly) NSArray<LFDiagnosticsEntry *> *entries;  // newest first
@property(nonatomic, readonly) NSUInteger allowCount;
@property(nonatomic, readonly) NSUInteger hideCount;
@property(nonatomic, readonly) NSUInteger unknownCount;
// Renderers and cells that were looked at but were not video items at all.
@property(nonatomic, readonly) NSUInteger skippedCount;

- (void)recordSource:(NSString *)source
             surface:(LFSurface)surface
                info:(nullable NSDictionary<NSString *, NSString *> *)info
            decision:(LFDecision)decision
              hidden:(BOOL)hidden;

- (void)recordSkipped;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
