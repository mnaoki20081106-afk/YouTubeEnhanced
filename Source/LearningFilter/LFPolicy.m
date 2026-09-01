#import "LFPolicy.h"
#import "LFCommon.h"
#import "LFMetadata.h"
#import "LFSubscriptionStore.h"

#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Gates

BOOL LFShouldBlockSubscriptionChanges(void) {
    return LFBoolDefaultYes(LFEnabledKey) && LFBoolDefaultYes(LFBlockSubscribeKey);
}

BOOL LFAccountIsBound(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:LFAccountBoundKey];
}

void LFMarkAccountBound(void) {
    if (LFAccountIsBound())
        return;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:LFAccountBoundKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

void LFClearAccountBinding(void) {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:LFAccountBoundKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSInteger LFSignedInAccountCount(void) {
    // Reflection over the account stores is cheap but not free, and this is
    // consulted once per element renderer, so the answer is held briefly.
    static NSInteger cachedCount = -1;
    static NSTimeInterval cachedAt = 0;
    static const NSTimeInterval cacheTTL = 5.0;
    if (cachedAt > 0 && NSDate.timeIntervalSinceReferenceDate - cachedAt < cacheTTL)
        return cachedCount;

    // The account list lives in Google's SSO framework, which YouTube links, and
    // is mirrored by YouTube's own identity store. Neither is part of any public
    // header, so both are probed by reflection and either may be absent.
    static NSArray<NSArray<NSString *> *> *probes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        probes = @[
            @[@"SSOAccountStore", @"sharedInstance", @"allAccounts"],
            @[@"SSOAccountStore", @"sharedInstance", @"accounts"],
            @[@"SSOAccountStore", @"defaultStore", @"allAccounts"],
            @[@"YTAccountsDataStore", @"sharedInstance", @"identities"],
            @[@"YTIdentityStore", @"sharedInstance", @"identities"],
            @[@"YTAccountsService", @"sharedInstance", @"identities"],
        ];
    });

    for (NSArray<NSString *> *probe in probes) {
        @try {
            Class storeClass = NSClassFromString(probe[0]);
            if (!storeClass)
                continue;

            SEL accessor = NSSelectorFromString(probe[1]);
            if (![storeClass respondsToSelector:accessor])
                continue;

            id store = ((id(*)(id, SEL))objc_msgSend)(storeClass, accessor);
            id accounts = LFValueForKey(store, probe[2]);
            NSInteger count = -1;
            if ([accounts isKindOfClass:[NSArray class]])
                count = (NSInteger)((NSArray *)accounts).count;
            else if ([accounts isKindOfClass:[NSSet class]])
                count = (NSInteger)((NSSet *)accounts).count;
            if (count >= 0) {
                cachedCount = count;
                cachedAt = NSDate.timeIntervalSinceReferenceDate;
                return count;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    cachedCount = -1;
    cachedAt = NSDate.timeIntervalSinceReferenceDate;
    return -1;
}

BOOL LFShouldBlockAccountAddition(void) {
    if (!LFBoolDefaultYes(LFEnabledKey) || !LFBoolDefaultYes(LFSingleAccountKey))
        return NO;

    NSInteger count = LFSignedInAccountCount();
    if (count >= 0) {
        if (count >= 1) {
            LFMarkAccountBound();
        } else if (LFAccountIsBound()) {
            // The account was signed out. The whitelist described that account's
            // subscriptions, so it goes with it — the next account brings its own.
            LFClearAccountBinding();
            [[LFSubscriptionStore sharedInstance] reset];
        }
        return count >= 1;
    }

    // The account list could not be read; fall back to whether an account has
    // ever been observed on this install.
    return LFAccountIsBound();
}

#pragma mark - Runtime guards

// Neutering replaces a method with one that does nothing and returns an empty
// value. Whether a method is neutered is decided once, at install time, from the
// settings — which is why both policy switches are documented as needing an app
// restart. Deciding it per call would mean forwarding to the original
// implementation, and a block cannot forward an arbitrary signature; that
// restriction is what would otherwise leave multi-argument methods such as
// -subscribeToChannel:from:completionHandler: unguarded.
//
// The replacement ignores whatever arguments the caller passes, which is safe
// because it never reads them. Only void, object and BOOL returns are handled:
// a struct return needs a matching block signature to be ABI-correct, so those
// methods are left alone.
static void LFNeuterMethod(Class cls, SEL selector) {
    if (!cls || !selector)
        return;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return;

    const char *types = method_getTypeEncoding(method);
    if (!types || types[0] == '\0')
        return;

    id replacementBlock = nil;
    switch (types[0]) {
        case 'v':
            replacementBlock = ^(__unused id target) {
            };
            break;
        case '@':
            replacementBlock = ^id(__unused id target) {
                return nil;
            };
            break;
        case 'B':
        case 'c':
            replacementBlock = ^BOOL(__unused id target) {
                return NO;
            };
            break;
        default:
            return;
    }

    IMP replacement = imp_implementationWithBlock(replacementBlock);
    // class_addMethod fails only when the class implements the selector itself;
    // when the method is inherited, adding it overrides just this class and
    // leaves every sibling untouched.
    if (!class_addMethod(cls, selector, replacement, types))
        method_setImplementation(method, replacement);
}

static BOOL LFStringHasAnyPrefix(NSString *value, NSArray<NSString *> *prefixes) {
    for (NSString *prefix in prefixes) {
        if ([value hasPrefix:prefix])
            return YES;
    }
    return NO;
}

static BOOL LFStringContainsAny(NSString *value, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }
    return NO;
}

static void LFNeuterMatchingMethods(Class cls, NSArray<NSString *> *selectorPrefixes) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    if (!methods)
        return;

    for (unsigned int index = 0; index < methodCount; index++) {
        SEL selector = method_getName(methods[index]);
        if (LFStringHasAnyPrefix(NSStringFromSelector(selector), selectorPrefixes))
            LFNeuterMethod(cls, selector);
    }
    free(methods);
}

void LFInstallPolicyGuards(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL blockSubscriptions = LFShouldBlockSubscriptionChanges();
        // Reading the gate first refreshes the sticky "an account is bound" flag
        // from the live account list, so a sign-in that happened in the previous
        // session is already reflected here.
        BOOL blockAccountAddition = LFShouldBlockAccountAddition();
        BOOL limitAccounts = LFBoolDefaultYes(LFEnabledKey) && LFBoolDefaultYes(LFSingleAccountKey);
        if (!blockSubscriptions && !(limitAccounts && blockAccountAddition))
            return;

        // Action selectors only. State accessors such as -setSubscribed: are left
        // alone: they render the subscriptions the account already has, which the
        // whitelist depends on and requirement 5 says not to disturb.
        NSArray<NSString *> *subscriptionSelectors = @[
            @"subscribeTo", @"unsubscribeFrom", @"performSubscri", @"performUnsubscri", @"handleSubscri",
            @"handleUnsubscri", @"didTapSubscri", @"didPressSubscri", @"subscribeButtonPressed",
            @"unsubscribeButtonPressed", @"toggleSubscri", @"requestSubscri", @"requestUnsubscri",
            @"addSubscription", @"removeSubscription", @"subscribeWith", @"unsubscribeWith"
        ];
        // Adding an account only. Switching identities is deliberately not
        // guarded: YouTube also uses those methods to activate the one account
        // that is signed in, and blocking them would sign the user out.
        NSArray<NSString *> *accountSelectors = @[
            @"addAccount", @"didTapAddAccount", @"presentAddAccount", @"showAddAccount", @"handleAddAccount",
            @"onAddAccount", @"addAccountWith", @"signInWithNewAccount", @"presentSignInFlowForNewAccount"
        ];

        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        if (!classes)
            return;

        for (unsigned int index = 0; index < classCount; index++) {
            Class cls = classes[index];
            const char *rawName = class_getName(cls);
            if (!rawName)
                continue;
            NSString *name = @(rawName);

            // Keep the sweep inside YouTube's and Google's own classes.
            if (!LFStringHasAnyPrefix(name, @[@"YT", @"GOO", @"SSO", @"ELM"]))
                continue;

            if (blockSubscriptions && LFStringContainsAny(name, @[@"subscri"]))
                LFNeuterMatchingMethods(cls, subscriptionSelectors);

            // Adding an account is only blocked once one is signed in, so these
            // methods are left alone entirely on an install that has never seen
            // an account: the first sign-in has to work.
            if (limitAccounts && blockAccountAddition && LFStringContainsAny(name, @[@"account", @"identity", @"signin"]))
                LFNeuterMatchingMethods(cls, accountSelectors);
        }

        free(classes);
    });
}
