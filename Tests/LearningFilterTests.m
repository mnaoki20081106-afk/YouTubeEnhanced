// Learning Filter — tests for the parts that can run off-device.
//
// The whitelist store, the identity normalisation, the guide harvester and the
// shared allow/hide decision are plain Foundation code, so they are exercised
// here against the matrix from the specification:
//
//   A = subscribed, B = subscribed, C = not subscribed
//   Home / Search / Shorts / Related  ->  A shown, B shown, C hidden
//
// Run with Tests/run.sh (GNUstep on Linux, or Apple's Foundation on macOS).
// The hook layer itself needs YouTube and is verified on device.

#import <Foundation/Foundation.h>

#import "../Source/LearningFilter/LFCommon.h"
#import "../Source/LearningFilter/LFFilter.h"
#import "../Source/LearningFilter/LFHarvest.h"
#import "../Source/LearningFilter/LFMetadata.h"
#import "../Source/LearningFilter/LFSubscriptionStore.h"

static NSUInteger gChecks = 0;
static NSUInteger gFailures = 0;

static void Check(BOOL condition, NSString *what) {
    gChecks++;
    if (condition) {
        printf("  ok   %s\n", what.UTF8String);
    } else {
        gFailures++;
        printf("  FAIL %s\n", what.UTF8String);
    }
}

static void Section(NSString *name) {
    printf("\n%s\n", name.UTF8String);
}

static NSDictionary *Info(NSString *channelId, NSString *handle, NSString *name) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (channelId)
        info[LFInfoChannelIdKey] = channelId;
    if (handle)
        info[LFInfoHandleKey] = handle;
    if (name)
        info[LFInfoChannelKey] = name;
    info[LFInfoTitleKey] = @"Some video";
    return info;
}

// Channel A and B are subscribed, C is not.
static NSString *const kChannelA = @"UCAAAAAAAAAAAAAAAAAAAAAA";
static NSString *const kChannelB = @"UCBBBBBBBBBBBBBBBBBBBBBB";
static NSString *const kChannelC = @"UCCCCCCCCCCCCCCCCCCCCCCC";

static void ResetDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[
             LFEnabledKey, LFFilterHomeKey, LFFilterSearchKey, LFFilterShortsKey, LFFilterRelatedKey, LFStrictKey,
             LFBlockSubscribeKey, LFSingleAccountKey, LFSubscribedChannelIdsKey, LFSubscribedHandlesKey,
             LFSubscribedNamesKey, LFManualNamesKey, LFAccountBoundKey
         ])
        [defaults removeObjectForKey:key];
    [defaults synchronize];
    [[LFSubscriptionStore sharedInstance] reset];
}

static void TestNormalisation(void) {
    Section(@"identity normalisation");

    Check([LFNormalizeChannelId(kChannelA) isEqualToString:kChannelA], @"a bare channel id is accepted");
    Check([LFNormalizeChannelId([NSString stringWithFormat:@"https://www.youtube.com/channel/%@", kChannelA])
              isEqualToString:kChannelA],
          @"a channel id is recovered from a URL");
    Check(LFNormalizeChannelId(@"UCtooshort") == nil, @"a short lookalike is rejected");
    Check(LFNormalizeChannelId([kChannelA stringByAppendingString:@"XYZ"]) == nil,
          @"a longer base64url run starting with UC is rejected");

    Check([LFNormalizeHandle(@"@MathChannel") isEqualToString:@"@mathchannel"], @"a handle is lowercased");
    Check([LFNormalizeHandle(@"https://www.youtube.com/@MathChannel/videos") isEqualToString:@"@mathchannel"],
          @"a handle is recovered from a URL");
    Check(LFNormalizeHandle(@"email me at a@b.com") == nil, @"a stray @ in free text is not a handle");

    Check([LFNormalizeChannelName(@"  Math   Channel ✓ ") isEqualToString:@"math channel"],
          @"a display name is folded and stripped of badges");
    Check(LFNormalizeChannelName(@"   ") == nil, @"an empty name is rejected");
}

static void TestStore(void) {
    Section(@"whitelist store");
    ResetDefaults();
    LFSubscriptionStore *store = [LFSubscriptionStore sharedInstance];

    Check(store.isEmpty, @"the store starts empty");
    Check(!LFFilteringActive(), @"filtering is inert while the whitelist is empty (signed out)");

    [store recordSubscribedChannelId:kChannelA handle:@"@mathA" name:@"Math Channel A"];
    [store recordSubscribedChannelId:kChannelB handle:nil name:@"Physics Channel B"];

    Check(!store.isEmpty, @"the store holds the harvested channels");
    Check([store isSubscribedToChannelId:kChannelA], @"A is subscribed by id");
    Check([store isSubscribedToChannelId:kChannelB], @"B is subscribed by id");
    Check(![store isSubscribedToChannelId:kChannelC], @"C is not subscribed");
    Check([store isSubscribedToHandle:@"@MATHA"], @"handle matching is case-insensitive");
    Check([store isSubscribedToChannelName:@"  math channel a "], @"name matching folds case and whitespace");
    Check(![store isSubscribedToChannelName:@"English Channel C"], @"an unsubscribed name does not match");

    [store forgetChannelId:kChannelB handle:nil name:@"Physics Channel B"];
    Check(![store isSubscribedToChannelId:kChannelB], @"a channel can be dropped when the account unsubscribes");
}

static void TestHarvest(void) {
    Section(@"guide harvesting");
    ResetDefaults();

    // Shaped like the protobuf text dump a guide response produces.
    NSString *guide = [NSString stringWithFormat:@"\n"
                                                  "pivot_bar_renderer {\n"
                                                  "  item { browse_id: \"FEwhat_to_watch\" title: \"Home\" }\n"
                                                  "}\n"
                                                  "guide_subscriptions_section_renderer {\n"
                                                  "  item {\n"
                                                  "    guide_entry_renderer {\n"
                                                  "      formatted_title { text: \"Math Channel A\" }\n"
                                                  "      navigation_endpoint {\n"
                                                  "        browse_endpoint { browse_id: \"%@\" canonical_base_url: \"/@matha\" }\n"
                                                  "      }\n"
                                                  "    }\n"
                                                  "  }\n"
                                                  "  item {\n"
                                                  "    guide_entry_renderer {\n"
                                                  "      formatted_title { text: \"Physics Channel B\" }\n"
                                                  "      navigation_endpoint {\n"
                                                  "        browse_endpoint { browse_id: \"%@\" canonical_base_url: \"/@physicsb\" }\n"
                                                  "      }\n"
                                                  "    }\n"
                                                  "  }\n"
                                                  "}\n",
                                                 kChannelA, kChannelB];

    Check(LFHarvestFromDescription(guide), @"the guide response grows the whitelist");

    LFSubscriptionStore *store = [LFSubscriptionStore sharedInstance];
    Check([store isSubscribedToChannelId:kChannelA], @"channel A was harvested");
    Check([store isSubscribedToChannelId:kChannelB], @"channel B was harvested");
    Check(![store isSubscribedToChannelId:kChannelC], @"an unsubscribed channel was not harvested");
    Check([store isSubscribedToHandle:@"@matha"], @"the handle was harvested");
    Check([store isSubscribedToChannelName:@"Math Channel A"], @"the channel title was harvested");
    Check(![store isSubscribedToChannelName:@"Home"], @"pivot bar labels are not mistaken for channels");
    Check(!LFHarvestFromDescription(guide), @"a repeated harvest reports no change");
}

static void TestDecisionMatrix(void) {
    Section(@"allow / hide matrix");
    ResetDefaults();

    LFSubscriptionStore *store = [LFSubscriptionStore sharedInstance];
    [store recordSubscribedChannelId:kChannelA handle:@"@matha" name:@"Math Channel A"];
    [store recordSubscribedChannelId:kChannelB handle:@"@physicsb" name:@"Physics Channel B"];

    Check(LFFilteringActive(), @"filtering is active once a whitelist exists");

    NSDictionary *a = Info(kChannelA, @"@matha", @"Math Channel A");
    NSDictionary *b = Info(kChannelB, @"@physicsb", @"Physics Channel B");
    NSDictionary *c = Info(kChannelC, @"@englishc", @"English Channel C");

    struct {
        LFSurface surface;
        const char *name;
    } surfaces[] = {{LFSurfaceHome, "home"},
                    {LFSurfaceSearch, "search"},
                    {LFSurfaceShorts, "shorts"},
                    {LFSurfaceRelated, "related"}};

    for (NSUInteger index = 0; index < sizeof(surfaces) / sizeof(surfaces[0]); index++) {
        LFSurface surface = surfaces[index].surface;
        const char *name = surfaces[index].name;
        Check(!LFShouldHideInfo(a, surface), [NSString stringWithFormat:@"%s: A is shown", name]);
        Check(!LFShouldHideInfo(b, surface), [NSString stringWithFormat:@"%s: B is shown", name]);
        Check(LFShouldHideInfo(c, surface), [NSString stringWithFormat:@"%s: C is hidden", name]);
    }

    Section(@"identity precedence");
    // A video from C that borrows a subscribed channel's display name must stay
    // hidden: the id it carries is the stronger identifier.
    Check(LFShouldHideInfo(Info(kChannelC, nil, @"Math Channel A"), LFSurfaceHome),
          @"a lookalike name cannot override an unsubscribed channel id");
    // Where a cell exposes nothing but the name, the name decides.
    Check(!LFShouldHideInfo(Info(nil, nil, @"Math Channel A"), LFSurfaceHome),
          @"a name-only cell from a subscribed channel is shown");
    Check(LFShouldHideInfo(Info(nil, nil, @"English Channel C"), LFSurfaceHome),
          @"a name-only cell from an unsubscribed channel is hidden");

    Section(@"unidentifiable content");
    NSDictionary *unknown = @{LFInfoTitleKey: @"A video with no readable owner"};
    Check(LFShouldHideInfo(unknown, LFSurfaceHome), @"strict mode hides content with no channel identity");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFStrictKey];
    Check(!LFShouldHideInfo(unknown, LFSurfaceHome), @"with strict mode off it is shown instead");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFStrictKey];

    Section(@"switches");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFFilterSearchKey];
    Check(!LFShouldHideInfo(c, LFSurfaceSearch), @"search filtering can be switched off on its own");
    Check(LFShouldHideInfo(c, LFSurfaceHome), @"and home filtering keeps working");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFFilterSearchKey];

    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFEnabledKey];
    Check(!LFFilteringActive(), @"the master switch turns everything off");
    Check(!LFShouldHideInfo(c, LFSurfaceHome), @"nothing is hidden while the filter is off");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFEnabledKey];
}

static void TestElementPayload(void) {
    Section(@"element renderer payloads");

    // A cell payload is protobuf; the identifiers inside it are plain UTF-8, so a
    // synthetic blob carrying a watch URL and a channel URL is enough to check
    // that the scanner finds them.
    NSString *payload = [NSString stringWithFormat:@"\x12\x1fhttps://www.youtube.com/channel/%@\x1a\x0b"
                                                    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq.jpg /@matha ",
                                                   kChannelA];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *info = LFVideoInfoFromElementData(data);

    Check([info[LFInfoChannelIdKey] isEqualToString:kChannelA], @"the channel id is read out of the payload");
    Check([info[LFInfoHandleKey] isEqualToString:@"@matha"], @"the handle is read out of the payload");
    Check([info[LFInfoVideoIdKey] isEqualToString:@"dQw4w9WgXcQ"], @"the video id is read out of the thumbnail URL");

    Check(LFChannelIdsInString(@"no identifiers here").count == 0, @"text without identifiers yields nothing");
}

int main(void) {
    @autoreleasepool {
        printf("Learning Filter tests\n");
        TestNormalisation();
        TestStore();
        TestHarvest();
        TestDecisionMatrix();
        TestElementPayload();
        ResetDefaults();

        printf("\n%lu checks, %lu failures\n", (unsigned long)gChecks, (unsigned long)gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
