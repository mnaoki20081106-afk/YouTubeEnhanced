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
#import "../Source/LearningFilter/LFDiagnostics.h"
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
             LFBlockSubscribeKey, LFSingleAccountKey, LFStrictFallbackKey, LFDryRunKey, LFDiagnosticsKey, LFSubscribedChannelIdsKey, LFSubscribedHandlesKey,
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
    Check([store isSubscribedToChannelName:@"Physics Channel B"], @"the second channel title was harvested");
    Check(![store isSubscribedToChannelName:@"/@matha"], @"a canonical URL is not stored as a channel title");
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

// A protobuf payload is mostly non-printable bytes with UTF-8 strings embedded
// in it, and the scanners run over the raw buffer. Building payloads that way
// here is the point: a scanner that only worked on clean ASCII would pass a
// string-based test and fail on the device.
static NSData *BinaryPayload(NSArray<NSString *> *strings) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t noise[] = {0x0a, 0x9f, 0x01, 0x12, 0x00, 0xff, 0xfe, 0x08, 0x01};
    for (NSString *string in strings) {
        [data appendBytes:noise length:sizeof(noise)];
        NSData *encoded = [string dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t length = (uint8_t)MIN(encoded.length, (NSUInteger)255);
        [data appendBytes:&length length:1];
        [data appendData:encoded];
    }
    [data appendBytes:noise length:sizeof(noise)];
    return data;
}

static void TestByteScanners(void) {
    Section(@"payload byte scanning");

    NSData *payload = BinaryPayload(@[
        [NSString stringWithFormat:@"https://www.youtube.com/channel/%@", kChannelA],
        @"https://www.youtube.com/@mathA/videos",
        @"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
    ]);
    NSDictionary *info = LFVideoInfoFromElementData(payload);

    Check([info[LFInfoChannelIdKey] isEqualToString:kChannelA], @"a channel id survives surrounding binary");
    Check([info[LFInfoHandleKey] isEqualToString:@"@matha"], @"a handle survives surrounding binary");
    Check([info[LFInfoVideoIdKey] isEqualToString:@"dQw4w9WgXcQ"], @"a video id survives surrounding binary");

    // A token that merely starts with "UC" and keeps going must not be mistaken
    // for a channel id.
    NSData *decoy = BinaryPayload(@[@"UCabcdefghijklmnopqrstuvwxyz0123456789"]);
    Check(LFChannelIdsInData(decoy).count == 0, @"an over-long base64url run is not a channel id");

    NSData *glued = BinaryPayload(@[[NSString stringWithFormat:@"XX%@", kChannelA]]);
    Check(LFChannelIdsInData(glued).count == 0, @"a channel id glued to a longer token is rejected");

    NSData *two = BinaryPayload(@[kChannelA, kChannelB]);
    NSArray<NSString *> *both = LFChannelIdsInData(two);
    Check(both.count == 2 && [both[0] isEqualToString:kChannelA] && [both[1] isEqualToString:kChannelB],
          @"several channel ids come back in order, without duplicates");

    NSData *repeated = BinaryPayload(@[kChannelA, kChannelA, kChannelA]);
    Check(LFChannelIdsInData(repeated).count == 1, @"a repeated channel id is reported once");

    NSData *shorts = BinaryPayload(@[@"https://www.youtube.com/shorts/abcDEF12345"]);
    Check([LFVideoInfoFromElementData(shorts)[LFInfoVideoIdKey] isEqualToString:@"abcDEF12345"],
          @"a Shorts URL yields the video id");

    // A bare "@name" in a title is not a handle; only a "/@name" path is.
    NSData *titleWithAt = BinaryPayload(@[@"Live @home with the band"]);
    Check(LFVideoInfoFromElementData(titleWithAt)[LFInfoHandleKey] == nil,
          @"an @ inside a title is not read as a handle");

    Check(LFVideoInfoFromElementData([NSData data]) == nil, @"an empty payload yields nothing");
    Check(LFVideoInfoFromElementData(nil) == nil, @"a nil payload yields nothing");
}

static void TestDryRunAndDiagnostics(void) {
    Section(@"dry run");
    ResetDefaults();

    LFSubscriptionStore *store = [LFSubscriptionStore sharedInstance];
    [store recordSubscribedChannelId:kChannelA handle:nil name:@"Math Channel A"];
    NSDictionary *c = Info(kChannelC, nil, @"English Channel C");

    Check(LFShouldHideInfo(c, LFSurfaceHome), @"an unsubscribed channel is hidden normally");
    Check(LFDecisionForInfo(c) == LFDecisionHide, @"and the decision says hide");

    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFDryRunKey];
    Check(!LFShouldHideInfo(c, LFSurfaceHome), @"dry run hides nothing");
    Check(LFDecisionForInfo(c) == LFDecisionHide, @"but the decision is still computed, so it can be recorded");
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFDryRunKey];

    Section(@"diagnostics");
    LFDiagnostics *diagnostics = [LFDiagnostics sharedInstance];
    [diagnostics reset];
    [diagnostics recordSource:@"renderer" surface:LFSurfaceHome info:c decision:LFDecisionHide hidden:YES];
    [diagnostics recordSource:@"cell"
                      surface:LFSurfaceSearch
                         info:Info(kChannelA, nil, @"Math Channel A")
                     decision:LFDecisionAllow
                       hidden:NO];

    Check(diagnostics.entries.count == 2, @"decisions are recorded");
    Check(diagnostics.hideCount == 1 && diagnostics.allowCount == 1, @"and counted by outcome");
    // Newest first, so the settings screen opens on what just happened.
    Check([diagnostics.entries.firstObject.channelName isEqualToString:@"Math Channel A"],
          @"the newest entry comes first");
    Check([diagnostics.entries.firstObject.detail containsString:kChannelA],
          @"an entry shows the channel id that was read");
    Check([diagnostics.entries.lastObject.summary containsString:@"HIDDEN"],
          @"an entry says whether the item was actually hidden");

    [diagnostics reset];
    Check(diagnostics.entries.count == 0 && diagnostics.hideCount == 0, @"diagnostics can be cleared");
}

static void TestStrictSafetyValve(void) {
    Section(@"strict-mode safety valve");
    ResetDefaults();
    LFResetStrictSuspension();

    [[LFSubscriptionStore sharedInstance] recordSubscribedChannelId:kChannelA handle:nil name:@"Math Channel A"];

    NSDictionary *unknown = @{LFInfoTitleKey: @"A video with no readable owner"};
    NSDictionary *known = Info(kChannelA, nil, @"Math Channel A");

    Check(LFShouldHideInfo(unknown, LFSurfaceHome), @"the first unidentifiable item is hidden");
    Check(!LFStrictSuspended(), @"and the valve has not tripped");

    // Whatever the threshold is, a long enough run of unidentifiable items has to
    // stop the filter emptying the app.
    for (NSUInteger index = 0; index < 40; index++)
        LFShouldHideInfo(unknown, LFSurfaceHome);

    Check(LFStrictSuspended(), @"a long run of unidentifiable items trips the valve");
    Check(!LFShouldHideInfo(unknown, LFSurfaceHome), @"and unidentifiable content stops being hidden");
    // The whitelist still does its job for everything that *can* be identified.
    Check(!LFShouldHideInfo(known, LFSurfaceHome), @"a subscribed channel is still shown");
    Check(LFShouldHideInfo(Info(kChannelC, nil, @"English Channel C"), LFSurfaceHome),
          @"an unsubscribed channel is still hidden");

    Check(!LFStrictSuspended(), @"identifying anything again re-arms strict mode");
    Check(LFShouldHideInfo(unknown, LFSurfaceHome), @"so unidentifiable content is hidden once more");

    // The valve can be switched off for anyone who wants strict mode absolute.
    LFResetStrictSuspension();
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFStrictFallbackKey];
    for (NSUInteger index = 0; index < 40; index++)
        LFShouldHideInfo(unknown, LFSurfaceHome);
    Check(LFShouldHideInfo(unknown, LFSurfaceHome), @"with the valve disabled, strict mode never gives up");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFStrictFallbackKey];
    LFResetStrictSuspension();
}

static void TestEpoch(void) {
    Section(@"cache invalidation");
    ResetDefaults();

    NSUInteger before = LFFilterEpoch();
    [[LFSubscriptionStore sharedInstance] recordSubscribedChannelId:kChannelA handle:nil name:@"Math Channel A"];
    Check(LFFilterEpoch() != before, @"harvesting a channel invalidates cached verdicts");

    NSUInteger afterHarvest = LFFilterEpoch();
    LFBumpFilterEpoch();
    Check(LFFilterEpoch() != afterHarvest, @"so does changing a setting");
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
        TestByteScanners();
        TestDryRunAndDiagnostics();
        TestStrictSafetyValve();
        TestEpoch();
        ResetDefaults();

        printf("\n%lu checks, %lu failures\n", (unsigned long)gChecks, (unsigned long)gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
