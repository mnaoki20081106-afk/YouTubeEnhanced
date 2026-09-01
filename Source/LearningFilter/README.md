# Learning Filter

Whitelist mode for uYouEnhanced: **only channels the signed-in YouTube account is
currently subscribed to may supply content**. Home, search, Shorts and related
videos are all filtered against that one list. New subscriptions are blocked, and
only one account may be signed in.

Everything here is additive. No existing uYouEnhanced feature is removed or
rewritten — SponsorBlock, PiP, YTUHD, the download extension, the playback and
UI tweaks all keep working, and the whole hook group is only installed when the
feature is switched on.

---

## What the whitelist is

Not a list you maintain. The whitelist **is** the account's subscription list,
read out of YouTube's own data:

| Source | What it yields | When |
|---|---|---|
| Guide response (`YTGuideServiceCoordinator`) | channel ids, handles, titles | on launch, whenever YouTube refreshes the guide |
| Subscriptions tab feed cells | id + handle + name for one channel, exactly paired | while that tab is on screen |
| Cells shown as already subscribed | id and name | as encountered |

The store only ever grows during a session, so a half-loaded guide never shrinks
the whitelist underneath a feed that is already being filtered. It is dropped
entirely when the account signs out.

Three identifier forms are kept, because different cell templates expose
different ones:

- **channel id** — `UCxxxxxxxxxxxxxxxxxxxxxx`, the strongest
- **handle** — `@example`
- **display name** — the weakest, and the only thing some cells carry

They are ranked rather than OR-ed. When a cell exposes an id or a handle, that
decides; a display name can never overrule an id that is present and simply not
subscribed. Otherwise a channel could get itself whitelisted by copying a
subscribed channel's name.

## The decision

One predicate, used by every surface (`LFFilter.h`):

```objc
BOOL LFIsAllowedChannel(NSString *channelId, NSString *handle, NSString *channelName) {
    return LFIsSubscribedToChannel(channelId, handle, channelName);
}
```

Whitelist == subscriptions. The indirection stays because that equivalence is the
specification, not an implementation detail.

Three outcomes, from `LFDecisionForInfo`:

- **allow** — subscribed
- **hide** — identified, not subscribed
- **unknown** — no channel identity could be read

Unknown is hidden while *strict mode* is on, which is the default. A video whose
owner cannot be determined is never given the benefit of the doubt.

Two states switch filtering off entirely, both deliberate:

- the master switch is off;
- the whitelist is empty. Signed out, there is no subscription list, so there is
  no whitelist to apply. Hiding everything in that state would leave a blank app
  with no way back to a sign-in screen, so it stays inert instead and the
  settings screen says so.

## Where it hooks

| Layer | Hook | Why |
|---|---|---|
| Before layout | `YTIElementRenderer -elementData` | returning `nil` drops the cell before it is measured, so no gap is left behind. Same mechanism uYouEnhanced already uses for ads and Shorts. |
| After layout | `YTAsyncCollectionView -layoutSubviews` / `-reloadData` / `-didMoveToWindow` | catches cells with no element renderer — the Shorts pager, some related rows |
| Shorts pager | same pass | a disallowed Short is scrolled past rather than hidden, since hiding a full-screen page leaves a blank screen |
| Whitelist | `YTGuideServiceCoordinator -handleResponse:…` | the guide carries the subscription list |
| Subscriptions | runtime method neutering + `subscribe_button` templates dropped | requirement: no new subscriptions, and no unsubscribing either |
| Accounts | runtime method neutering + `add_account` templates dropped | one account only |

Surfaces are told apart two ways: from the element template name before layout
(`compact_video` → related, `shorts_video_cell` → Shorts, and so on), and from
the live responder chain afterwards. Neither depends on a guessed selector, so a
YouTube update degrades the classification rather than breaking it.

## Subscriptions and accounts

Subscribe and unsubscribe are blocked by neutering the action methods on classes
whose names match `YT*Subscri*`, plus dropping subscribe-button element
templates. State accessors such as `-setSubscribed:` are deliberately left alone:
they render the subscriptions the account already has, which the whitelist
depends on.

Account addition is blocked the same way, but only once an account is actually
signed in, so the first sign-in always works. Signing out stays possible; when
the account list drops back to zero the lock releases and the whitelist is
cleared. Switching identities is *not* neutered — YouTube uses those same methods
to activate the one account that is signed in, and blocking them would sign the
user out. With a second account impossible to add, there is nothing to switch to.

Both policies are decided once at startup, which is why their settings say an app
restart is required: deciding per call would mean forwarding to the original
implementation, and a block cannot forward an arbitrary method signature.

## Relationship to Gonerino

Gonerino solves the same underlying problem — YouTube's iOS feeds are
AsyncDisplayKit nodes wrapping opaque element-renderer protobufs, and a cell's
channel is spread across whichever layer the current template happens to use. Its
approach is reused rather than its code depended on:

- the reflective `ValueForObjectKey` walk over node graphs;
- the element-renderer protobuf scan, including the finding that fields 36 and 37
  are the video title and the channel display name;
- the `YTAsyncCollectionView` filtering loop with its scroll and re-entrancy
  guards;
- the Shorts pager advance.

The logic is inverted — Gonerino hides a *blocked* channel, this shows only a
*subscribed* one — and the extraction is extended, since Gonerino only needs the
display name while a whitelist wants the channel id and handle too.

## Files

| File | Role |
|---|---|
| `LFCommon.h` | preference keys and defaults |
| `LFSubscriptionStore.{h,m}` | the whitelist, and identity normalisation |
| `LFMetadata.{h,m}` | channel identity out of nodes and element payloads |
| `LFFilter.{h,m}` | the shared allow/hide decision |
| `LFHarvest.{h,m}` | turning YouTube's data into the whitelist |
| `LFPolicy.{h,m}` | subscription and account rules |
| `LearningFilter.xm` | the hooks |

Settings live under **YouTubePlus → Learning Filter**.

## Tests

`Tests/run.sh` builds and runs the decision layer off-device, covering the
acceptance matrix (two subscribed channels shown, one unsubscribed hidden, on
each of home, search, Shorts and related), identity normalisation, guide
harvesting, identifier ranking and the strict-mode behaviour. The hook layer
needs YouTube itself and is verified on device.

## Known limitations

- The subscribe action in YouTube's *native* long-press action sheet is only
  covered by the method neutering, not by template removal; if a build routes it
  through a class outside the `YT*Subscri*` naming, it would need adding.
- Channel display names harvested from the guide are matched to their channel by
  proximity in the response dump. That is why names rank below ids: a mismatch
  can only affect cells that expose nothing but a name.
- The autoplay endscreen is not filtered directly; it draws from the watch-next
  response, whose related list is.
