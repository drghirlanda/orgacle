;;; orgacle-appearance.el --- Per-slide appearance for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Per-slide appearance: a heading's ORGACLE_TEXT_SCALE property remaps
;; the buffer-local `default' face's height for just that slide, via
;; `face-remap-add-relative'/`face-remap-remove-relative' rather than
;; `text-scale-set' -- the latter is itself built on the same
;; `face-remapping-alist' mechanism, but through a single buffer-wide
;; "how many steps" slot (`text-scale-mode-amount') that a presenter's
;; own prior `text-scale-adjust' use in this buffer could already be
;; using for something else, and its LEVEL argument is a count of
;; `text-scale-mode-step' multiplications rather than a height a
;; presenter can read off `orgacle-text-scale' and reuse directly.
;; `face-remap-add-relative' returns a cookie scoped to exactly the one
;; remapping it added, so removing it can never disturb anything else
;; already in `face-remapping-alist', and its own float-versus-integer
;; `:height' convention already matches `orgacle-text-scale' and
;; `orgacle-scalable-faces' exactly, with no translation needed.
;;
;; A heading's ORGACLE_BACKGROUND property sets the `background-color'
;; frame parameter of the *session's* frame -- `orgacle--get-frame' had
;; to be fixed in an earlier phase for reading the selected frame
;; instead, so this reads the session's frame slot directly, the same
;; way that fix left every other frame-facing call in the package.
;; This half is not exercised by `make test': batch Emacs has no
;; graphical frame, so every batch test here that touches it observes
;; only the documented no-op guard, `(frame-live-p frame)' false.  It
;; was instead verified with a real, non-batch Emacs process connected
;; to an `Xvfb' virtual display (`DISPLAY=:99 Emacs -Q ...', no
;; `--batch'; batch Emacs errors on `x-open-connection' with "Unknown
;; terminal type"): confirmed `frame-parameter' after `make-frame'
;; returns a concrete colour string, never nil, so
;; appearance-default-background is never captured as nil on a live
;; frame; confirmed `set-frame-parameter' accepts any string for
;; `background-color' with no validation of its own, silently, which is
;; exactly why this file checks `color-defined-p' itself before
;; applying one; and confirmed `color-defined-p' returns non-nil for an
;; ordinary colour name and nil for a made-up one on that same live
;; frame.  Also ran `orgacle-run' itself, unstubbed, under that same
;; Xvfb session, against test/fixtures/appearance.org, and read the
;; frame's actual `background-color' parameter and the buffer's actual
;; `face-remapping-alist' at each step, not just messages about them:
;; slide 1 (\"Both slide\", 2.0 and \"red\") showed height (:height 2.0)
;; and background \"red\"; slide 2 (\"Plain slide\", no properties) showed
;; no height entry at all and background back to \"white\", the frame's
;; own default captured at creation -- the live version of
;; `orgacle-test-appearance-text-scale-is-reset-entering-a-plain-slide',
;; confirming the reset half of this feature with a real frame, not
;; only the buffer-local half batch already covers; slide 3
;; (\"Absolute slide\", 600 only) showed height (:height 600) and
;; background still \"white\"; slide 4 (\"Malformed slide\", \"banana\" and
;; \"not-a-real-colour\") showed no height entry and background \"white\",
;; matching `orgacle-test-appearance-malformed-text-scale-is-ignored'
;; for the frame parameter too; stepping back to slide 1 with three
;; `p' presses showed (:height 2.0) and \"red\" again; and `orgacle-quit'
;; left the frame dead (`frame-live-p' nil) and the buffer's
;; `face-remapping-alist' nil.

;;; Code:

(require 'org)
(require 'face-remap)
(require 'orgacle-core)

(defun orgacle--appearance-text-scale ()
  "Return the current slide's ORGACLE_TEXT_SCALE as a positive number, or nil.
Reads the property at point, the same way `orgacle-slide-in-effect' and
`orgacle-show-file-auto' read their own ORGACLE_* properties, relying
on the page-hook contract that a member runs with point at the current
slide's heading -- unlike `orgacle-reveal.el', which locates the slide
from the session's slides/index slots instead, because its own
functions are also called from `orgacle-refresh', off a keybinding,
where point is wherever the presenter was editing, not necessarily the
heading; `orgacle--apply-appearance' has no such caller, only the page
hook, so point is reliable here.

A missing property, or one that is present but not a positive number
after `string-to-number' -- an empty string, a non-numeric value such
as \"banana\", zero, or a negative number -- both return nil: no
distinction is drawn between \"not set\" and \"set to something
unusable\", so a presenter's typo behaves exactly like the property
being absent rather than breaking the slide or spamming the log on
every visit; see `orgacle-test-appearance-malformed-text-scale-is-ignored'
for how this was verified against a real malformed value, both for the
buffer-local remapping and for the absence of any new log entry."
  (let ((value (org-entry-get nil "ORGACLE_TEXT_SCALE")))
    (when value
      (let ((number (string-to-number value)))
        (and (> number 0) number)))))

(defun orgacle--appearance-background ()
  "Return the current slide's raw ORGACLE_BACKGROUND property, or nil.
Unlike `orgacle--appearance-text-scale', no parsing happens here: any
non-empty string is a candidate colour, and
`orgacle--appearance-apply-background' is what decides, via
`color-defined-p', whether it is actually usable."
  (org-entry-get nil "ORGACLE_BACKGROUND"))

(defun orgacle-appearance-clean-text-scale ()
  "Remove the session's current text-scale remapping, if any; reset the slot.
Safe to call with nothing to clean -- a session that never applied
ORGACLE_TEXT_SCALE at all -- the same no-op contract
`orgacle-reveal-clean-overlays' has.  Called by
`orgacle--appearance-apply-text-scale' before every slide change, by
`orgacle-quit', and by `orgacle-run' before it replaces the outgoing
session; see those call sites for why each needs it.

The session's appearance-text-scale slot holds a (BUFFER . COOKIE)
cons rather than the cookie alone, and this always removes the
remapping in that recorded BUFFER via `with-current-buffer', not
whatever buffer happens to be current at the call site: `orgacle-quit'
in particular calls this before it has necessarily switched to any
particular buffer, and a narrowed presentation's actual presented
buffer -- a temporary export buffer -- is not the session's own
org-buffer slot; see the appearance-text-scale slot's own docstring on
the `orgacle--session' struct in orgacle-core.el.  Guarded on
`buffer-live-p' first: the buffer may already be gone, for example
because a narrowed presentation's temporary buffer was killed by
`orgacle-quit' itself, in the branch that runs before this one; there
is then nothing to remove a remapping from, and nothing to do."
  (let* ((session (orgacle--session-ensure))
         (entry (orgacle--session-appearance-text-scale session)))
    (when entry
      (when (buffer-live-p (car entry))
        (with-current-buffer (car entry)
          (face-remap-remove-relative (cdr entry))))
      (setf (orgacle--session-appearance-text-scale session) nil))))

(defun orgacle--appearance-apply-text-scale ()
  "Remove the previous slide's text-scale remapping and apply this one's.
Always calls `orgacle-appearance-clean-text-scale' first, unconditionally
-- regardless of whether the slide now at point has an ORGACLE_TEXT_SCALE
of its own -- which is what keeps a slide's remapping from surviving
into the next slide: the same leak class `orgacle-reveal-reset' guards
against for reveal overlays, and Step 3's whole point for this task.
Only adds a fresh remapping when `orgacle--appearance-text-scale'
returns a usable value; a slide with no property, or a malformed one,
leaves the buffer exactly at its unremapped, ordinary height, having
paid for nothing more than the cleanup call and one property lookup."
  (orgacle-appearance-clean-text-scale)
  (let ((value (orgacle--appearance-text-scale)))
    (when value
      (let ((session (orgacle--session-ensure))
            (cookie (face-remap-add-relative 'default (list :height value))))
        (setf (orgacle--session-appearance-text-scale session)
              (cons (current-buffer) cookie))))))

(defun orgacle--appearance-apply-background ()
  "Restore the session frame's background, then override it if requested.
A no-op when the session has no live frame -- true throughout the
batch test suite, and true of any session on which `orgacle--get-frame'
has never run -- since there is then nothing to set a frame parameter
on; see orgacle-appearance.el's Commentary for how this was verified
with a real one instead.

Restores `background-color' to the session's appearance-default-background
slot -- the same \"undo, then maybe reapply\" shape
`orgacle--appearance-apply-text-scale' uses -- so a slide with no
ORGACLE_BACKGROUND property looks exactly like the deck's own default,
not whatever colour a previous slide left behind, then overrides that
when the current slide's ORGACLE_BACKGROUND is both present and a
colour `color-defined-p' recognizes on this frame; a missing or
unrecognized value -- a typo, for instance -- leaves the just-restored
default in place rather than signalling or applying a nonsense value,
so a presenter's mistake never breaks navigation and never leaves a
stray colour on screen for the rest of the talk.

Only actually calls `set-frame-parameter' when the target colour
differs from what the frame's `background-color' already is: a deck
that never sets ORGACLE_BACKGROUND would otherwise still make one such
call on every single slide, over and over restoring the frame to a
colour it was already showing -- a real, if small, per-redisplay X
round-trip a presenter who never touches this feature should not pay,
the same \"costs nothing when unused\" standard the reveal-* and
appearance-text-scale slots already meet by staying nil until
something actually uses them."
  (let* ((session (orgacle--session-ensure))
         (frame (orgacle--session-frame session)))
    (when (frame-live-p frame)
      (let* ((default
              (orgacle--session-appearance-default-background session))
             (value (orgacle--appearance-background))
             (target (if (and value (color-defined-p value frame))
                         value default)))
        (unless (equal target (frame-parameter frame 'background-color))
          (set-frame-parameter frame 'background-color target))))))

(defun orgacle--apply-appearance ()
  "Apply the current slide's ORGACLE_TEXT_SCALE and ORGACLE_BACKGROUND.
A member of `orgacle-page-hook', so this runs every time a slide is
displayed, entering it from either direction or redisplaying it in
place; see this file's own `add-hook' call below for why it has to run
before `orgacle-slide-in-effect' specifically, and
`orgacle--appearance-apply-text-scale'/`orgacle--appearance-apply-background'
for what each half actually does and how each undoes the previous
slide's own settings first."
  (orgacle--appearance-apply-text-scale)
  (orgacle--appearance-apply-background))

;; Joins `orgacle-page-hook' at load time with no APPEND, i.e.
;; prepended, for the same reason orgacle-reveal.el's own `add-hook'
;; call is: `orgacle-slide-in-effect' (registered by orgacle-fontify.el)
;; calls `sit-for', forcing a real redisplay mid-animation, so anything
;; not yet applied by then -- an in-progress reveal there, a slide's
;; text scale or background here -- is visible to the audience for the
;; whole slide-in pause.  `orgacle-test-appearance-runs-before-slide-in-sit-for'
;; pins this directly, by stubbing `sit-for' itself and checking what is
;; already in `face-remapping-alist' at the moment of its first call;
;; confirmed by hand that swapping this call to APPEND-t makes that
;; test fail before restoring the plain prepend below.
;;
;; A bare (prepend) `add-hook' call only needs this file's own require
;; in orgacle.el to come after orgacle-fontify.el's, which registers
;; `orgacle-slide-in-effect' the same way; it does not need to come
;; after orgacle-media.el's or orgacle-notes.el's requires, since
;; neither `orgacle-show-file-auto'/`orgacle-show-indicators-maybe' nor
;; `orgacle-position-notes' forces a redisplay the way slide-in does.
;; This file is required last of the six page-hook contributors --
;; after orgacle-reveal.el -- which lands it ahead of
;; `orgacle-reveal-reset' too, but that ordering, unlike
;; appearance-before-slide-in, is not a correctness dependency: text
;; scale and background touch buffer-local `face-remapping-alist' and a
;; frame parameter, reveal touches overlay `invisible' properties on
;; text ranges, and neither reads or writes anything the other one
;; does.  Placing appearance first here is a judgment call -- lowest
;; apparent risk, the same reasoning Task 3 used to place reveal last
;; relative to file/indicators/notes -- not a derived requirement; see
;; the hook-order test's docstring in test/orgacle-test.el, which says
;; so explicitly rather than asserting the two features cannot interact
;; without having checked.
(add-hook 'orgacle-page-hook #'orgacle--apply-appearance)

(provide 'orgacle-appearance)
;;; orgacle-appearance.el ends here
