// Learning Filter — hooks.
//
// Everything here funnels into LFFilter's single decision so that home, search,
// Shorts and related videos cannot drift apart (requirement 8). Nothing in this
// file changes existing uYouEnhanced behaviour: the hooks are additive and the
// whole group is only initialised when the feature is switched on.

#import "LFCommon.h"
#import "LFDiagnostics.h"
#import "LFFilter.h"
#import "LFHarvest.h"
#import "LFMetadata.h"
#import "LFPolicy.h"
#import "LFSubscriptionStore.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface YTAsyncCollectionView : UICollectionView
@property(nonatomic, assign) BOOL lfFiltering;
@property(nonatomic, assign) BOOL lfFilterScheduled;
@property(nonatomic, assign) NSTimeInterval lfLastFilterTime;
// The surface this view belongs to, plus one, so that zero means "not worked out
// yet". Walking the responder chain is cheap but not free, and layoutSubviews
// runs constantly.
@property(nonatomic, assign) NSInteger lfCachedSurface;
- (void)lfScheduleFiltering;
@end

@interface _ASCollectionViewCell : UICollectionViewCell
- (id)node;
@end

@interface YTIElementRenderer : NSObject
- (NSData *)elementData;
- (BOOL)lfShouldDropElementData:(NSData *)data;
@end

static void *LFRendererVerdictKey = &LFRendererVerdictKey;

#pragma mark - Surface detection

// Which feed a view belongs to, read from the responder chain. Using the live
// hierarchy rather than a guessed selector keeps this working across YouTube
// versions: the controller names are what change least.
static LFSurface LFSurfaceForView(UIView *view) {
    UIResponder *responder = view;
    NSUInteger depth = 0;
    while (responder && depth++ < 24) {
        NSString *name = NSStringFromClass([responder class]).lowercaseString;
        if ([name containsString:@"reel"] || [name containsString:@"shorts"])
            return LFSurfaceShorts;
        if ([name containsString:@"search"])
            return LFSurfaceSearch;
        if ([name containsString:@"watchnext"] || [name containsString:@"related"] ||
            [name containsString:@"watchlayer"])
            return LFSurfaceRelated;
        responder = responder.nextResponder;
    }
    return LFSurfaceHome;
}

// The surface whose feed is currently being built. Element renderers are asked
// for their payload while a collection view lays out, but a renderer has no way
// back to the view it will end up in — and building its description just to read
// a template name is the most expensive thing on this path, since the
// description of a message carrying a 100 KB payload is a 100 KB string. The
// collection view pass records the surface here instead.
static LFSurface gCurrentSurface = LFSurfaceHome;

static LFSurface LFCurrentSurface(void) {
    return gCurrentSurface;
}

static BOOL LFViewIsOnSubscriptionsFeed(UIView *view) {
    UIResponder *responder = view;
    NSUInteger depth = 0;
    while (responder && depth++ < 24) {
        NSString *name = NSStringFromClass([responder class]).lowercaseString;
        if ([name containsString:@"subscription"])
            return YES;
        responder = responder.nextResponder;
    }
    return NO;
}

#pragma mark - Element renderer templates

static BOOL LFDescriptionContainsAny(NSString *description, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([description containsString:needle])
            return YES;
    }
    return NO;
}

// Template names for the cells that carry a single video owned by one channel.
// This is a hint, not the test: YouTube renames templates between versions, so
// the primary signal is the payload itself (below). Anything that matches
// neither is left alone, so shelves, headers, comments and chrome are never
// touched by this filter.
static BOOL LFTemplateIsVideoCell(NSString *description) {
    return LFDescriptionContainsAny(description, @[
        @"video_with_context", @"compact_video", @"search_video", @"grid_video", @"video_lockup",
        @"shorts_video_cell", @"reel_item", @"rich_item", @"playlist_video"
    ]);
}

// A payload that embeds a watch or thumbnail URL describes a video. That holds
// across versions because the URL shape is part of YouTube's own API, not of a
// client-side template name — which is why it, and not the template, decides.
static BOOL LFPayloadIsVideoCell(NSDictionary<NSString *, NSString *> *info) {
    return info[LFInfoVideoIdKey] != nil;
}

static LFSurface LFSurfaceForTemplate(NSString *description) {
    if (LFDescriptionContainsAny(description, @[@"shorts", @"reel"]))
        return LFSurfaceShorts;
    if (LFDescriptionContainsAny(description, @[@"compact_video", @"watch_next"]))
        return LFSurfaceRelated;
    if (LFDescriptionContainsAny(description, @[@"search"]))
        return LFSurfaceSearch;
    return LFSurfaceHome;
}

static BOOL LFTemplateIsSubscribeControl(NSString *description) {
    return LFDescriptionContainsAny(description, @[@"subscribe_button", @"subscription_button", @"subscribe_entity"]);
}

static BOOL LFTemplateIsAddAccountControl(NSString *description) {
    return LFDescriptionContainsAny(description, @[@"add_account", @"account_add", @"add_identity"]);
}

#pragma mark - Feed refresh

static void LFFilterVisibleCells(YTAsyncCollectionView *collectionView);

static void LFRefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (!keyWindow)
            keyWindow = UIApplication.sharedApplication.windows.firstObject;
        if (!keyWindow)
            return;

        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:keyWindow];
        Class collectionViewClass = NSClassFromString(@"YTAsyncCollectionView");
        while (pending.count > 0) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if (collectionViewClass && [view isKindOfClass:collectionViewClass]) {
                [view setNeedsLayout];
                LFFilterVisibleCells((YTAsyncCollectionView *)view);
            }
            [pending addObjectsFromArray:view.subviews];
        }
    });
}

#pragma mark - Cell filtering

static void *LFHiddenCellKey = &LFHiddenCellKey;

static BOOL LFCollectionViewIsScrolling(YTAsyncCollectionView *collectionView) {
    return collectionView.isDragging || collectionView.isDecelerating || collectionView.isTracking;
}

static id LFNodeForCell(UICollectionViewCell *cell) {
    Class asCellClass = NSClassFromString(@"_ASCollectionViewCell");
    if (asCellClass && [cell isKindOfClass:asCellClass] && [cell respondsToSelector:@selector(node)])
        return [(_ASCollectionViewCell *)cell node];
    return LFValueForKey(cell, @"asyncdisplaykit_node");
}

static void LFSetCellHidden(UICollectionViewCell *cell, BOOL hidden) {
    objc_setAssociatedObject(cell, LFHiddenCellKey, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = hidden;
    cell.alpha = hidden ? 0.0 : 1.0;
    cell.userInteractionEnabled = !hidden;
    cell.accessibilityElementsHidden = hidden;
}

// The Shorts player is a vertical pager: hiding the page leaves a blank screen,
// so a disallowed Short is skipped past instead.
static void LFAdvanceShortsPager(YTAsyncCollectionView *collectionView, UICollectionViewCell *cell) {
    NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
    if (indexPath && indexPath.section < collectionView.numberOfSections) {
        NSInteger nextItem = indexPath.item + 1;
        if (nextItem < [collectionView numberOfItemsInSection:indexPath.section]) {
            [collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:nextItem
                                                                       inSection:indexPath.section]
                                   atScrollPosition:UICollectionViewScrollPositionTop
                                           animated:YES];
            return;
        }
    }

    CGFloat pageHeight = MAX(collectionView.bounds.size.height, 1.0);
    CGFloat maximumOffset = MAX(collectionView.contentSize.height - pageHeight, 0.0);
    CGFloat target = MIN(collectionView.contentOffset.y + pageHeight, maximumOffset);
    [collectionView setContentOffset:CGPointMake(collectionView.contentOffset.x, target) animated:YES];
}

static void LFFilterVisibleCells(YTAsyncCollectionView *collectionView) {
    if (!collectionView || LFCollectionViewIsScrolling(collectionView) || collectionView.lfFiltering)
        return;

    BOOL onSubscriptionsFeed = LFViewIsOnSubscriptionsFeed(collectionView);
    // Only ever raised here, never lowered: a nested collection view elsewhere on
    // the same screen must not cancel it, and it lapses on its own.
    if (onSubscriptionsFeed)
        LFSetOnSubscriptionsSurface(YES);

    // The Subscriptions tab is the whitelist's own source: everything shown there
    // is subscribed by definition, so it feeds the store instead of being judged
    // by it.
    if (!onSubscriptionsFeed && !LFFilteringActive())
        return;

    LFSurface surface;
    if (collectionView.lfCachedSurface > 0) {
        surface = (LFSurface)(collectionView.lfCachedSurface - 1);
    } else {
        surface = LFSurfaceForView(collectionView);
        collectionView.lfCachedSurface = (NSInteger)surface + 1;
    }
    gCurrentSurface = surface;

    if (!onSubscriptionsFeed && !LFSurfaceEnabled(surface))
        return;

    collectionView.lfFiltering = YES;
    collectionView.lfLastFilterTime = NSDate.timeIntervalSinceReferenceDate;

    @try {
        for (UICollectionViewCell *cell in collectionView.visibleCells) {
            id node = LFNodeForCell(cell);
            if (!node)
                continue;

            if (onSubscriptionsFeed) {
                if (LFNodeLooksLikeVideo(node))
                    LFHarvestFromInfo(LFVideoInfoFromNode(node));
                continue;
            }

            if (!LFNodeLooksLikeVideo(node)) {
                // A recycled cell may have been hidden while holding other content.
                if (objc_getAssociatedObject(cell, LFHiddenCellKey))
                    LFSetCellHidden(cell, NO);
                continue;
            }

            NSDictionary<NSString *, NSString *> *info = LFVideoInfoFromNode(node);
            LFDecision decision = LFDecisionForInfo(info);
            BOOL hide = LFShouldHideInfo(info, surface);
            [[LFDiagnostics sharedInstance] recordSource:@"cell"
                                                 surface:surface
                                                    info:info
                                                decision:decision
                                                  hidden:hide];

            if (hide && collectionView.pagingEnabled) {
                LFSetCellHidden(cell, NO);
                LFAdvanceShortsPager(collectionView, cell);
                continue;
            }
            LFSetCellHidden(cell, hide);
        }
    } @catch (__unused NSException *exception) {
    }

    collectionView.lfFiltering = NO;
}

#pragma mark - Guide harvesting

static void LFHarvestGuideResponse(id response) {
    if (!response)
        return;

    NSString *description = nil;
    @try {
        // Taken here rather than on the worker queue: the caller is about to hand
        // this response on, and other tweaks — uYouEnhanced's own tab replacement
        // among them — mutate it. Reading it after that has started would be a
        // race. The resulting string is immutable, so parsing it off-thread is
        // safe.
        description = [response description];
    } @catch (__unused NSException *exception) {
        return;
    }
    if (description.length == 0)
        return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (LFHarvestFromDescription(description)) {
                // Subscriptions can only be read while signed in, so a successful
                // harvest is also proof that an account is bound.
                LFMarkAccountBound();
            }
        } @catch (__unused NSException *exception) {
        }
    });
}

#pragma mark - Hooks

%group gLearningFilter

// Pre-layout filtering. Dropping the payload removes the cell before it is ever
// measured, which avoids the gaps that hiding a laid-out cell leaves behind.
// This is the same mechanism uYouEnhanced already uses to strip ads and Shorts.
%hook YTIElementRenderer

%new
- (BOOL)lfShouldDropElementData:(NSData *)data {
    NSDictionary<NSString *, NSString *> *info = LFVideoInfoFromElementData(data);
    BOOL filtering = LFFilteringActive() && !LFOnSubscriptionsSurface();

    // The payload settles most items without ever building the renderer's
    // description, which is the expensive call on this path.
    if (LFPayloadIsVideoCell(info)) {
        if (!filtering) {
            [[LFDiagnostics sharedInstance] recordSkipped];
            return NO;
        }

        LFSurface surface = LFCurrentSurface();
        if (!LFSurfaceEnabled(surface)) {
            [[LFDiagnostics sharedInstance] recordSkipped];
            return NO;
        }

        LFDecision decision = LFDecisionForInfo(info);
        BOOL hide = LFShouldHideInfo(info, surface);
        [[LFDiagnostics sharedInstance] recordSource:@"renderer"
                                             surface:surface
                                                info:info
                                            decision:decision
                                              hidden:hide];
        return hide;
    }

    NSString *description = [self description];
    if (description.length == 0)
        return NO;

    // Template match first: it is a substring test, while the gates reach into
    // the account store.
    if (LFTemplateIsSubscribeControl(description) && LFShouldBlockSubscriptionChanges())
        return YES;

    if (LFTemplateIsAddAccountControl(description) && LFShouldBlockAccountAddition())
        return YES;

    if (!filtering || !LFTemplateIsVideoCell(description)) {
        [[LFDiagnostics sharedInstance] recordSkipped];
        return NO;
    }

    // A cell the template says is a video, but whose payload gave up nothing.
    // Strict mode decides what happens to it.
    LFSurface surface = LFSurfaceForTemplate(description);
    if (!LFSurfaceEnabled(surface)) {
        [[LFDiagnostics sharedInstance] recordSkipped];
        return NO;
    }

    LFDecision decision = LFDecisionForInfo(info);
    BOOL hide = LFShouldHideInfo(info, surface);
    [[LFDiagnostics sharedInstance] recordSource:@"renderer"
                                         surface:surface
                                            info:info
                                        decision:decision
                                          hidden:hide];
    return hide;
}

- (NSData *)elementData {
    NSData *data = %orig;
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return data;

    @try {
        if (!LFBoolDefaultYes(LFEnabledKey))
            return data;

        // elementData is read repeatedly for the same renderer, and answering it
        // means scanning the payload and often building the renderer's
        // description. The verdict is therefore kept on the renderer and only
        // recomputed when the whitelist or a setting has moved underneath it.
        NSUInteger epoch = LFFilterEpoch();
        NSNumber *cached = objc_getAssociatedObject(self, LFRendererVerdictKey);
        if (cached) {
            NSUInteger stored = cached.unsignedIntegerValue;
            if (stored / 2 == epoch)
                return (stored % 2) ? nil : data;
        }

        BOOL drop = [self lfShouldDropElementData:data];
        objc_setAssociatedObject(self, LFRendererVerdictKey, @(epoch * 2 + (drop ? 1 : 0)),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return drop ? nil : data;
    } @catch (__unused NSException *exception) {
    }

    return data;
}

%end

// Post-layout safety net. Cells built without an element renderer — the Shorts
// pager and some related-video rows — only become identifiable once their node
// exists, so they are judged here.
%hook YTAsyncCollectionView

%property(nonatomic, assign) BOOL lfFiltering;
%property(nonatomic, assign) BOOL lfFilterScheduled;
%property(nonatomic, assign) NSTimeInterval lfLastFilterTime;
%property(nonatomic, assign) NSInteger lfCachedSurface;

%new
- (void)lfScheduleFiltering {
    if (!LFBoolDefaultYes(LFEnabledKey))
        return;
    if (self.lfFilterScheduled || LFCollectionViewIsScrolling(self))
        return;
    if (NSDate.timeIntervalSinceReferenceDate - self.lfLastFilterTime < 0.35)
        return;

    self.lfFilterScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
            return;
        strongSelf.lfFilterScheduled = NO;
        LFFilterVisibleCells(strongSelf);
    });
}

- (void)layoutSubviews {
    %orig;
    [self lfScheduleFiltering];
}

- (void)reloadData {
    %orig;
    [self lfScheduleFiltering];
}

- (void)didMoveToWindow {
    %orig;
    self.lfCachedSurface = 0;
    if (self.window)
        [self lfScheduleFiltering];
}

%end

// The guide response carries the account's whole subscription list. It is the
// primary whitelist source (requirement 4).
%hook YTGuideServiceCoordinator

- (void)handleResponse:(id)response withCompletion:(id)completion {
    LFHarvestGuideResponse(response);
    %orig;
}

- (void)handleResponse:(id)response error:(id)error completion:(id)completion {
    LFHarvestGuideResponse(response);
    %orig;
}

%end

%end  // gLearningFilter

#pragma mark - Init

%ctor {
    if (!LFBoolDefaultYes(LFEnabledKey))
        return;

    %init(gLearningFilter);

    // The guards sweep the whole class list; doing it on the first runloop turn
    // keeps it off the launch path, and still lands long before any subscribe or
    // add-account control can be tapped.
    dispatch_async(dispatch_get_main_queue(), ^{
        LFInstallPolicyGuards();
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:LFWhitelistDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
                                                      LFRefreshVisibleFeeds();
                                                  }];

    // Flipping a switch in settings has to invalidate the verdicts already cached
    // on element renderers, or the feed would keep showing the old decision until
    // YouTube happened to rebuild it.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
                                                      LFBumpFilterEpoch();
                                                  }];
}
