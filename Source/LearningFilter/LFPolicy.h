// Learning Filter — subscription and account policy.
//
// Requirement 5: the account's existing subscriptions are the whitelist, but no
// new subscription may be made and none of the existing ones may be dropped.
// Requirement 6: at most one Google/YouTube account may be signed in; signing
// out and signing back in with a different single account stays possible.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Blocks every subscribe/unsubscribe action while the setting is on.
FOUNDATION_EXPORT BOOL LFShouldBlockSubscriptionChanges(void);

// Blocks adding a second account. Returns NO while no account is signed in, so
// the first sign-in always works.
FOUNDATION_EXPORT BOOL LFShouldBlockAccountAddition(void);

// Best-effort count of signed-in accounts, or -1 when it cannot be determined.
FOUNDATION_EXPORT NSInteger LFSignedInAccountCount(void);

// Sticky "an account has been seen on this install" flag, used when the count
// cannot be read. Cleared from settings after signing out.
FOUNDATION_EXPORT BOOL LFAccountIsBound(void);
FOUNDATION_EXPORT void LFMarkAccountBound(void);
FOUNDATION_EXPORT void LFClearAccountBinding(void);

// Installs the runtime guards on subscribe/unsubscribe and add-account methods.
// Safe to call once at startup; classes and selectors that do not exist in this
// YouTube build are skipped.
FOUNDATION_EXPORT void LFInstallPolicyGuards(void);

NS_ASSUME_NONNULL_END
