# UI/UX review

Written 2026-08-27 against this tree. Every claim below was grepped or read, not recalled,
and each says whether it is **measured** (something was counted or run) or **reasoned** (a
documented platform behaviour applied to this code). Standards consulted: Android's
edge-to-edge and target-API guidance, Flutter's accessibility documentation, WCAG 2.2
target sizes, and Material 3.

Ordered by what it costs a parent, not by effort.

**Status: §1, §2 and §6 are implemented** (2026-08-30), and their entries were deleted from
`docs/OPEN-FINDINGS.md` per that file's own first rule. They are kept below as written,
with what shipped marked, because this is the record of what was decided — not a list that
edits itself to match the code.

---

## 1. The notification is a dead end, and it sits on the product's only loop

**Shipped.** Approve and Deny actions, handled in a background isolate that installs the
pin for itself. Every path that does not end in the change being made posts a second
notification saying so — the notification is dismissed the instant an action is tapped,
before any network call, so a parent could otherwise tap Approve, watch it vanish, and be
wrong. One assumption died on contact: `approveTimeRequest` returns **false** for an
already-resolved request rather than throwing, so the first draft would have reported every
ordinary race as a hard failure.

**Measured.** `notifications.dart` sets no `actions:` and registers no tap handler —
`onDidReceiveNotificationResponse` appears nowhere. So the loop this whole app exists for
runs: child asks → phone buzzes → parent unlocks → finds the app → finds the right tab →
reads the row → presses Approve. Six steps to answer a yes/no question the notification
already stated in full.

Android has supported notification actions for a decade, `flutter_local_notifications`
exposes them as `AndroidNotificationAction`, and — the part that makes this cheap here —
**the machinery to act from the background already exists.** `openBackgroundSession()`
returns a pinned, signed-in client inside a background isolate; that is how the fifteen
minute poll works. An action handler needs that plus `approveTimeRequest`.

Two taps from a lock screen, no unlock. This is the single largest improvement available
to this app, and it is squarely in the grain of its own design: the parent acts where they
already are.

**Care needed.** Approving from a lock screen is a grant with no confirmation, so the
action should be *Approve* and *Deny* rather than a single ambiguous one, and it must
cancel the notification on success. See §6 on undo.

## 2. "You are away from home" reads exactly like "that PC is off"

**Shipped.** `whereAmI` asks this phone where it is before blaming that PC, from
`NetworkInterface.list()` — no package, no permission, and no second request to a PC that
has already failed to answer one. `NetworkInterface` does not expose a netmask, so the
subnet cannot be computed and this does not pretend otherwise: the wide case is the hedged
one, because telling a parent at home that they are away sends them to the wrong place. The
OS detail moved to `NestwatchException.detail`, where the harnesses still print it.

**Measured.** `nestwatch_api.dart` builds one message for every transport failure:

```dart
'Could not reach $authority. ${e.osError?.message ?? e.message}'
```

and `PolledScreenState.waitingPane` renders it verbatim. Nothing in `lib/` consults
connectivity — the only match for `wifi` in the whole tree is `allowWifiLock` in the
foreground service.

This is a **LAN-only app**. Leaving the house is not an error, it is the single most common
thing that will ever happen to it, and it produces the same screen as a broken PC — plus an
`errno` string a parent cannot act on.

The app already reasons well about the *adjacent* case: a 403 from `require_lan_peer` gets
a careful sentence about VPNs. But that only fires when the server answers. Off the network
there is nobody to answer, and the careful sentence never runs.

**Fix.** Consult connectivity before blaming the PC, and separate three states a parent can
act on differently: not on Wi-Fi at all, on a *different* Wi-Fi, or on the home network and
the PC is genuinely unreachable. Only the third is a problem with the PC.

## 3. Nothing in this app has a semantic label

**Measured.** `Semantics`, `semanticLabel`, `MergeSemantics` and `excludeSemantics` appear
**zero** times across `lib/`. Five `tooltip:` strings are the entire accessibility surface.

Three places where that is not a formality:

- **The screenshot.** `Image.memory` with no `semanticLabel`. A screen reader announces
  nothing at all for the one screen whose entire content is an image.
- **The fingerprint.** 95 characters of colon-separated hex in a `SelectableText`. Read
  aloud character by character, which is the least useful possible rendering of a value a
  parent is being asked to compare.
- **Approve and Deny.** Repeated once per row in a list. Out of visual context, a screen
  reader user hears "Approve, Approve, Approve" with nothing naming which request.

Flutter's Material buttons already meet the 48dp target automatically, so sizing is fine —
the gap here is labelling, which nothing gives you for free.

## 4. No `SafeArea`, and edge-to-edge is no longer optional

**Measured for the absence, reasoned for the consequence.** `SafeArea`, `viewPadding` and
`viewInsets` appear zero times in `lib/`. Flutter has defaulted to edge-to-edge since 3.27,
and for apps targeting API 36 Android **removed the opt-out** —
`windowOptOutEdgeToEdgeEnforcement` is deprecated and disabled. This app targets 36.

`Scaffold` handles the app bar and the bottom `NavigationBar`, so the four tabs are mostly
covered by their own chrome. The exposed screen is the one with no bottom chrome:
`pairing_screen.dart` is a `SingleChildScrollView` with a flat `EdgeInsets.all(20)`, and the
last thing in it is the privacy link — the one element Play requires to be reachable.

**Not confirmed on a device**, and it should be before anything is changed: this is exactly
the kind of claim that is obvious in theory and wrong on hardware.

## 5. Operating-system error text reaches the parent

**Measured.** `${e.osError?.message ?? e.message}` is concatenated into the message shown on
screen. A parent gets *"Connection refused"*, or *"No route to host"*, or whatever the
platform happens to say, appended to a sentence that was otherwise written for them.

Everywhere else this codebase is careful about exactly this — `explainMismatch` and the
`require_lan_peer` copy are both written for a person. This one line is where the discipline
stops. Keep the detail for the harnesses, which is where it is useful; give the screen the
sentence.

## 6. Approve grants minutes with no way back

**Superseded by §1 rather than fixed as written.** The undo was argued for the in-app
button; what shipped puts the same grant on a lock screen, where the risk is not a mis-tap
but a *silent* one. The effort went into telling the parent when an answer did not land. An
in-app undo is still worth having and is no longer urgent.

**Measured.** `time_requests_screen.dart` debounces via `_deciding` (PLAN §5 asks for that),
shows a `SnackBar` on completion, and offers no undo and no confirmation.

The server is idempotent under a mutex, so a double tap is safe — that is what the debounce
and the mutex are for. Neither helps the parent who tapped the wrong row. Granting screen
time is not destructive in the way deleting is, but it is not reversible from this app
either.

**Fix.** The SnackBar is already there; give it an `Undo` action for the few seconds it is
up. Cheaper and less irritating than a confirmation dialog, and it becomes necessary rather
than nice if §1 lands and approval moves to the lock screen.

## 7. The parent's app is English-only, while the child's page now speaks Dutch

**Measured.** 76 capitalised string literals of fifteen characters or more in `lib/src/ui`,
and `flutter_localizations` is not in `pubspec.yaml`.

nestwatch 0.4.0 added Dutch for the child's surfaces and deliberately kept the dashboard in
English. That was a reasoned decision about *the child's* page — "the person being watched
should not be the one choosing the language it is written in" — and it says nothing about
the parent's phone.

Not urgent, and not free: 76 strings is a real day of work and every future string joins
them. Worth deciding deliberately rather than defaulting.

## 8. Text scaling has never been exercised

**Measured.** No reference to `TextScaler` or `textScaler` anywhere, which is correct —
Flutter scales automatically and overriding it is usually the bug. The gap is that nothing
has been *looked at* above about 130%. The screens most likely to break are the ones with
fixed `SizedBox` heights and single-line `Row`s: the usage headline, and the request rows
where the button sits beside wrapping text.

Costs nothing to check, and a parental-control app has an above-average share of users who
have turned font size up.

## 9. Polish, in the order it is worth doing

- **Dynamic colour.** `ColorScheme.fromSeed` with a fixed seed, no `dynamic_color`. Material
  You wallpaper theming is a small, expected touch on Android 12+.
- **Predictive back.** `enableOnBackInvokedCallback` is not declared. Android 16 expects it.
- **Skeletons over spinners.** Every screen shows a bare `CircularProgressIndicator` before
  first paint; the shapes are known and stable enough to outline.
- **Haptics.** No `HapticFeedback` on approve or deny — the two moments in the app where a
  physical confirmation is worth something.

---

## Not findings

- **Touch targets.** All interactive elements are Material widgets, which enforce 48dp
  themselves. The one `size: 20` is an `Icon` inside an `IconButton`, which keeps its own
  target. Checked because it is the usual finding, and it is not one here.
- **Dark mode.** Both themes are built from one seed with explicit brightness. Correct.
- **Pull-to-refresh.** Present on the data screens, including a deliberate
  `AlwaysScrollableScrollPhysics` on the empty state so there is something to pull. That is
  the detail most apps miss.
- **Empty states.** Two screens have an explicit one — requests and codes, each with an
  icon and a sentence. A first draft of this review said three; the usage screen's
  `isEmpty` hides an empty *section*, not the screen, which is a different thing. It needs
  no empty state: the headline always renders, so a quiet day reads as "0 min used today"
  rather than as blankness. The screenshot screen's absence is deliberate too — it starts
  stopped, because streaming a child's desktop is a choice a parent makes.
