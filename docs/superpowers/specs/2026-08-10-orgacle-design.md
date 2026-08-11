# Orgacle — design

Date: 2026-08-10
Status: approved, pending implementation

Rework `epresent.el` (a private fork of `dakrone/epresent`) into `orgacle`, a
robust, modular, tested Org-mode presentation package fit for MELPA.

## 1. Context

`epresent.el` is a 1187-line single file. Upstream `dakrone/epresent` has been
dead since 2016; this fork carries 59 commits of new work added since 2020
(speaker notes, file/video display, fringe indicators, slide-in animation,
laser-pointer mouse, LaTeX/PDF export, speaking-time estimation).

The package works for its author but cannot be published as-is. Measured state
on Emacs 30.2:

- byte-compiler: no `lexical-binding` cookie; ~40 free-variable
  assignments; 12 obsolete Org APIs; 9 undefined functions.
- `package-lint`: ~60 errors (dependency floor, symbol prefix, reserved keys).
- `checkdoc`: ~80 docstring violations.
- tests: none. CI: none.

## 2. Goals

1. A package that installs cleanly for a stranger and does not break their Emacs.
2. A codebase that can be changed safely — modular, tested, CI-verified.
3. The features that are half-finished today, finished.
4. Four new presentation capabilities.
5. Accepted into MELPA.

## 3. Non-goals

- HTML/reveal.js export. The LaTeX/PDF backend stays; nothing new is added.
- Backward compatibility with `EPRESENT_*` properties at runtime (see §4.3).
- Supporting Emacs < 29.1.
- Merging back into `dakrone/epresent`.

## 4. Decisions

### 4.1 New package name: `orgacle`

MELPA's `epresent` recipe points at `dakrone/epresent`; MELPA does not accept a
fork under an existing package's name. `orgacle` is unclaimed on MELPA, GNU ELPA
and NonGNU ELPA.

Consequences: symbol prefix `orgacle-`, file `orgacle.el`, customization group
`orgacle`, properties `ORGACLE_*`, keywords `#+ORGACLE_*`. The GitHub repository
is renamed `drghirlanda/orgacle` (GitHub keeps a redirect from the old name).

Package header:

```elisp
;;; orgacle.el --- Presentation mode for Org-mode  -*- lexical-binding: t; -*-
;; Maintainer: Stefano Ghirlanda <drghirlanda@gmail.com>
;; URL: https://github.com/drghirlanda/orgacle
;; Version: 2.0.0
;; Keywords: outlines, hypermedia, multimedia
;; Package-Requires: ((emacs "29.1") (org "9.6"))
```

Prior authors (Tromey, Hagelberg, Schulte, Chaganti, Hinman) stay in the
`Authors:` header; the Commentary states the package's origin as a fork of
epresent. Version starts at 2.0.0 to signal discontinuity from epresent 1.5.0.
A `COPYING` file carrying GPL-3 is added.

### 4.2 Floor: Emacs 29.1 / Org 9.6

Emacs 29.1 bundles Org 9.6, the first release with `org-fold-*`. Using it as the
floor means the fold and visibility APIs are called directly, with no shim.

One shim remains: `org-link-preview-*` (Org 9.8, bundled with Emacs 31) replaced
`org-redisplay-inline-images` / `org-remove-inline-images` /
`org-inline-image-overlays`. These are called via `orgacle--link-preview-refresh`
and `orgacle--link-preview-clear` in `orgacle-core.el`, dispatching on `fboundp`.

CI matrix: 29.4, 30.2, snapshot.

### 4.3 Properties: `ORGACLE_*` only, with a migration command

Old decks are converted, not supported forever. `orgacle-migrate-buffer` and
`orgacle-migrate-file` rewrite `:EPRESENT_X:` to `:ORGACLE_X:` and
`#+EPRESENT_X:` to `#+ORGACLE_X:`, report the number of substitutions, and
operate on the region when one is active. This keeps every property lookup a
single unconditional call and removes a whole class of "which name won" bugs.

All lookups still route through one accessor, `orgacle--prop`, so that the
property namespace is defined in exactly one place.

### 4.4 Optional dependencies

Nothing beyond Emacs and Org is a hard requirement.

| Dependency | Today | Target |
|---|---|---|
| `org-superstar` | top-level `require` — **breaks install**, not declared in `Package-Requires` | `(require 'org-superstar nil t)`; `orgacle-use-org-superstar` defaults to t; absent package logs once and falls back to plain bullets |
| `pdf-tools` | 6 functions called unguarded | `declare-function` + `featurep` check; PDF display degrades to whatever mode Emacs picks |
| `image-mode` transforms | 2 functions called unguarded | `fboundp` guard |
| video player | `mplayer` hardcoded default, `vlc` alternative | `executable-find` over `orgacle-video-players` (mpv, mplayer, vlc; mpv first — mplayer is effectively dead) |

Rationale for keeping `org-superstar` out of `Package-Requires`: it is purely
cosmetic, and a presentation package should not drag in a bullet-styling package
for users who do not want it. The cost is one `fboundp` branch.

## 5. Architecture

### 5.1 Files

```
orgacle-core.el      defgroup, faces, defcustoms, session state, orgacle--prop,
                     compat shims, overlay bookkeeping, error logging
orgacle-nav.el       slide vector, page and subheading navigation     -> core
orgacle-fontify.el   overlay fontification and hiding                 -> core
orgacle-media.el     show-file (aux window, PDF, image), video, fringe indicators
                                                                      -> core
orgacle-notes.el     notes collection, presenter view, talk timer     -> core, nav
orgacle-reveal.el    incremental reveal                               -> core
orgacle-appearance.el per-slide background and text scale             -> core
orgacle.el           mode, keymap, orgacle-run / orgacle-quit, autoloads
                                                                      -> all above
ox-orgacle.el        LaTeX/PDF export backend                         -> ox-latex
```

Dependencies point one way only: feature modules depend on `orgacle-core`, never
on each other; `orgacle.el` depends on everything. `ox-orgacle.el` is loadable on
its own without starting a presentation.

Each file must byte-compile standalone with `byte-compile-error-on-warn`.

### 5.2 The page hook — the only inter-module interface

Today `epresent-current-page` hard-codes calls into five subsystems, and
`epresent-show-file` reaches into fringe-overlay state owned by the indicator
code. That coupling is why the `SHOW_AUTO`/indicator interaction took four
attempts to get right.

Replace it with one extension point:

```elisp
(defvar orgacle-page-hook nil
  "Hook run after a slide has been displayed and narrowed.")
```

`orgacle-media`, `orgacle-notes`, `orgacle-reveal` and `orgacle-appearance` each
add a function at load time. `orgacle--display-page` is then:

1. tear down the previous slide's transient state (aux window, fringe overlays,
   reveal overlays, appearance remapping);
2. narrow to the slide's subtree and set visibility;
3. run `orgacle-page-hook`.

Users get the same hook as an extension point.

### 5.3 Error handling

**Principle: once a presentation is running, nothing may drop the presenter out
of it.**

- Every `orgacle-page-hook` member runs inside `condition-case`. A failure
  appends to `*Orgacle Log*` (with slide index and backtrace) and the remaining
  hook members still run.
- `orgacle-show-file` on a missing file currently calls `user-error` mid-talk.
  It logs and returns instead.
- `orgacle-quit` is idempotent and wrapped in `unwind-protect`, so a broken
  session state cannot strand the user in a fullscreen frame.
- Missing optional dependencies produce one clear message, never a backtrace.

### 5.4 Session state

~20 loose global `defvar`s are mutated ad hoc today, and `epresent-quit`
restores some Org variables by hand while unconditionally calling `(org-mode)`.

Replace with:

- `orgacle--session`, a `cl-defstruct` holding frame, source buffer, restriction,
  temp file, slide vector, index, aux window, notes buffer, timer start.
- `orgacle--saved-globals`, an alist of `(symbol . value)` captured by
  `orgacle--save-user-state` from one declared list of variables and replayed by
  `orgacle--restore-user-state`. Adding a variable to the list is then a one-line
  change that cannot be forgotten on the restore side.

`orgacle-quit` locates its frame from the struct, not by comparing the frame
title to the string `"EPresent"`.

## 6. The slide model

The highest-value structural change; P3 depends on it and P4 builds on it.

Navigation today is `org-get-next-sibling` plus a recursive `skip` flag used to
step over the title page, and `epresent-jump-to-page` calls `epresent-top` then
loops `epresent-next-page`, re-rendering and re-animating every intervening
slide.

Replace with a vector built once at `orgacle-run`:

```elisp
(orgacle--session-slides  session)  ; vector of markers, one per real slide
(orgacle--session-index   session)  ; current position
```

A heading is a slide when it is at frame level and is not a title page, not
tagged/propertied `ORGACLE_HIDE`, and not a speaker-notes subtree. Navigation
becomes index arithmetic against that vector.

Bugs this eliminates as a class:

- title-page skip recursion between `current-page` / `next-page` /
  `previous-page` (four commits fought this);
- page-number drift during backward navigation;
- flickering, animation-firing `jump-to-page`, now O(1);
- notes-buffer positioning by regexp search on heading text, which breaks on
  duplicate headings — becomes an index lookup into a parallel marker vector;
- "slide N of M", required by the presenter view, now free.

## 7. Defects to fix

Confirmed by byte-compilation and reading. Phase in brackets.

**Dead code that errors when called** [P0]
- `epresent-increase-font` / `epresent-decrease-font` iterate over
  `epresent-content-face` and `epresent-fixed-face`. Neither face exists — the
  faces defined are title/heading/subheading/author/bullet/hidden. Both commands
  signal on invocation. Fix: operate on the faces that exist, and bind them to
  keys (they are currently unreachable from the keymap).
- `(setq org-hide-pretty-entities t)` in the mode body sets a variable that does
  not exist; the real one is `org-pretty-entities`, which is saved and restored
  but never actually changed. Pretty-entity handling has never worked.

**Invalid customization metadata** [P0]
- `epresent-tooltip-mode` — `:type 'bool` is not a valid customization type, and
  the value is used as a 0/1 mode argument. Becomes `orgacle-tooltips`,
  `:type 'boolean`, passed as `(if orgacle-tooltips 1 -1)`.
- `epresent-mode-line` — `:type 'string` but the value is a mode-line construct.
  Becomes `:type 'sexp`.
- `epresent-speaker-notes` — `:type 'string` but the value is a boolean.
- `(condition-case ex ... ('error ...))` — quoted condition name.
- `mark-whole-buffer` called from Lisp in the export backend.

**Portability** [P3]
- `x-pointer-shape`, `x-sensitive-text-pointer-shape` and `x-pointer-invisible`
  are X11-only. On pgtk, Wayland, macOS and Windows the laser-pointer code and
  `epresent-toggle-mouse` signal. Guard on `(boundp 'x-pointer-shape)` and
  degrade silently.

**Half-finished features** [P3]
- `epresent-internal-border-width` is docstringed `NOT WORKING`: the defcustom
  exists but `make-frame` hardcodes `(internal-border-width . 75)`. Fix by using
  the variable, applying it with `set-frame-parameter` after creation so reused
  frames pick up changes, and re-testing the reported fringe interaction (commit
  `f9bc35e` removed the customization because it disturbed fringe indicators —
  with indicators redesigned, retest rather than assume).
- Indicator / `SHOW_AUTO` cross-talk. Indicators become derived state: computed
  from the slide's properties, drawn by one page-hook member, cleared by one
  teardown function. `show-file` no longer touches indicator overlays.
- `epresent-quit` kills the notes frame via
  `(window-frame (get-buffer-window epresent-notes-buffer))`, which signals when
  the buffer is not displayed.

## 8. New capabilities [P4]

All four build on the slide vector.

- **Presenter view.** Promotes the existing notes frame to a console in
  `*Orgacle Presenter*`: current slide's notes, next slide's title, `N/M`,
  elapsed time, remaining time. Refreshed from `orgacle-page-hook`.
- **Talk timer.** Starts at `orgacle-run`. Target duration from
  `#+ORGACLE_DURATION:` (minutes). Shown in the mode line and the presenter view;
  face shifts at 90% and 100% of target. Complements the existing
  word-count-based speaking-time estimate.
- **Incremental reveal.** Generalizes `EPRESENT_STEPWISE`. Reveal targets for the
  current slide (list items, subheadings, blocks — selected by
  `:ORGACLE_REVEAL:`) are collected into a list; state is an index into it, so
  forward and backward are symmetric. This replaces the current
  hide-subtree/show-subtree hack, which cannot step backwards correctly.
  `n`/`p` advance the reveal first and change slide once it is exhausted;
  configurable.
- **Per-slide appearance.** `:ORGACLE_BACKGROUND:` and `:ORGACLE_TEXT_SCALE:`
  applied through buffer-local `face-remapping-alist` and a frame parameter,
  reset on every page change so no slide leaks styling into the next.

## 9. Testing

ERT, batch-runnable, no window system needed for the bulk.

Covered in batch: `#+ORGACLE_*` keyword parsing; `orgacle--prop`; slide-vector
construction over fixtures (nested levels, title page, hidden slides, speaker
notes); navigation and page numbering, forwards and backwards; notes collection;
speaking-time estimate; migration command; the export backend's property-drawer
translator; the reveal state machine; state save/restore round-trip.

Not testable in batch — frame creation, fringe rendering, mouse pointer shape,
slide-in animation, video playback. These are isolated behind thin wrapper
functions so that the logic around them is testable, and covered by an optional
`xvfb-run` smoke job that starts and quits a presentation.

Fixtures in `test/fixtures/*.org`. `present.org` becomes the manual end-to-end
demo and is migrated to `ORGACLE_*`.

Build and CI: Eldev; GitHub Actions matrix over Emacs 29.4 / 30.2 / snapshot;
jobs `compile` (with `byte-compile-error-on-warn`), `checkdoc`, `package-lint`,
`test`.

## 10. Phases

Each phase ends green — compile, lint, checkdoc and tests all pass — and is
independently committable.

### P0 — Safety net and compliance
Eldev setup, ERT harness, CI workflow, fixtures. Characterization tests for the
logic that is extractable today. Then `lexical-binding: t` and elimination of all
~40 free variables. Fix the invalid `defcustom` types and the dead-code defects
of §7. Docstrings to checkdoc-clean. Remove the load-time
`(define-key org-mode-map [f5] ...)` — MELPA forbids it and the keys are reserved
for users; ship an autoloaded command and document the binding.
`Package-Requires` set to the 29.1/9.6 floor.

Turning on `lexical-binding` is a semantic change at every one of those ~40
sites, which is exactly why the characterization tests come first in this phase
and not later.

**Exit:** byte-compile clean under `byte-compile-error-on-warn`; checkdoc clean;
`package-lint` clean; tests green on all three Emacs versions.

### P1 — Rename
Mechanical rename of symbols, file, group, faces, properties and keywords.
`orgacle-migrate-buffer` / `orgacle-migrate-file` with tests. README and
`present.org` updated.

Two steps in this phase are the maintainer's to perform, not automatable from
the working tree: renaming the GitHub repository to `drghirlanda/orgacle`
(GitHub leaves a redirect behind), and renaming the local checkout directory
from `epresent` to `orgacle`. Both are confirmed before P1 begins.

**Exit:** no `epresent` string outside the Commentary's origin note; tests green.

### P2 — Modularization and modernization
Split into the files of §5.1. Introduce `orgacle-page-hook` and remove sideways
calls. Replace the 12 obsolete Org APIs; add the `org-link-preview-*` shim.
Make `org-superstar`, `pdf-tools` and image transforms optional; detect the video
player with `executable-find`. Introduce `orgacle--session` and the
save/restore mechanism; make `orgacle-quit` idempotent.

**Exit:** each file byte-compiles standalone; tests green.

### P3 — Slide model and robustness
Build the slide vector; rewrite navigation as index arithmetic; O(1) jump.
Reposition notes by index. Fix the §7 portability and half-finished-feature
defects. Install the presentation-safe error handling of §5.3.

**Exit:** navigation tests cover nested, hidden, title-page and speaker-notes
fixtures forwards and backwards; no unguarded X11 call remains.

### P4 — New capabilities
The four features of §8, each with tests for its state machine.

**Exit:** tests green; each feature demonstrated in `present.org`.

### P5 — Ship
Fill the seven empty README sections (`The basics`, `Inline images`,
`Code blocks`, `Indicators`, `Speaker notes`, `Slide-in effect`,
`'Laser pointer' effect`). Screenshots
and a short screen recording. CHANGELOG, version 2.0.0. Submit the MELPA recipe
PR.

**Exit:** recipe merged.

## 11. Risks

- **`lexical-binding` surfaces latent behaviour.** Several of the ~40 free
  variables are read across function boundaries and currently work only through
  dynamic scope — `show-file` in the indicator code and `slide-local` in the
  slide-in code are the clearest cases. Mitigation: characterization tests
  before the switch; convert one function at a time.
- **The fringe/internal-border interaction may be genuinely unfixable.** Commit
  `f9bc35e` removed the border customization because of it. If retesting after
  the indicator redesign still shows a conflict, the fallback is to document the
  constraint and keep the border fixed, rather than ship a variable that lies.
- **MELPA review may object to the fork lineage.** Mitigation: the Commentary
  states the origin explicitly, authorship is preserved, and the name does not
  collide.
- **Uncommitted work in the tree.** `epresent.el`, `README.org` and `present.org`
  currently have uncommitted modifications, and `ltximg/` is untracked
  (`.gitignore` still lists Org's old `ltxpng` directory name). P0 starts by
  committing or discarding these and correcting `.gitignore`, so that the
  baseline is clean before any rewrite.
