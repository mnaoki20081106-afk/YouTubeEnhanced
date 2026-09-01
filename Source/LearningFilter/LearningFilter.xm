// Learning Filter — hooks.
//
// Everything here funnels into LFFilter's single decision so that home, search,
// Shorts and related videos cannot drift apart (requirement 8). Nothing in this
// file changes existing uYouEnhanced behaviour: the hooks are additive and the
// whole group is only initialised when the feature is switched on.

#import "LFCommon.h"
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
- (void)lfScheduleFiltering;
@end

@interface _ASCollectionViewCell : UICollectionViewCell
- (id)node;
@end

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

// The cell templates that carry a single video owned by one channel. Anything
// not listed here is left alone, so shelves, headers, comments and chrome are
// never removed by this filter.
static BOOL LFTemplateIsVideoCell(NSString *description) {
    return LFDescriptionContainsAny(description, @[
        @"video_with_context", @"compact_video", @"search_video", @"grid_video", @"video_lockup",
        @"shorts_video_cell", @"reel_item", @"rich_item", @"playlist_video"
    ]);
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
    LFSetOnSubscriptionsSurface(onSubscriptionsFeed);

    // The Subscriptions tab is the whitelist's own source: everything shown there
    // is subscribed by definition, so it feeds the store instead of being judged
    // by it.
    if (!onSubscriptionsFeed && !LFFilteringActive())
        return;

    LFSurface surface = LFSurfaceForView(collectionView);
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

            BOOL hide = LFShouldHideNode(node, surface);
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

    // A guide response is a large protobuf; dumping and scanning it is done off
    // the main thread so the launch path is untouched.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *description = [response description];
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

- (NSData *)elementData {
    NSData *data = %orig;
    if (![data isKindOfClass:[NSData class]] || data.length == 0)
        return data;

    @try {
        NSString *description = [self description];
        if (description.length == 0)
            return data;

        // Template match first: it is a substring test, while the gates reach into
        // the account store.
        if (LFTemplateIsSubscribeControl(description) && LFShouldBlockSubscriptionChanges())
            return nil;

        if (LFTemplateIsAddAccountControl(description) && LFShouldBlockAccountAddition())
            return nil;

        if (LFOnSubscriptionsSurface() || !LFFilteringActive())
            return data;

        if (!LFTemplateIsVideoCell(description))
            return data;

        LFSurface surface = LFSurfaceForTemplate(description);
        if (!LFSurfaceEnabled(surface))
            return data;

        if (LFShouldHideInfo(LFVideoInfoFromElementData(data), surface))
            return nil;
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
}
