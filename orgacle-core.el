;;; orgacle-core.el --- Shared state and helpers for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; The leaf module: the customization surface, the state a running
;; presentation keeps, the compatibility shims, and the helpers every other
;; module needs.  It requires nothing from the rest of the package, so the
;; feature modules can depend on it without a cycle.

;;; Code:

(require 'org)
(require 'cl-lib)

;;; Compatibility

;; Org 9.8 renamed the inline-image API to org-link-preview-*.  The floor
;; for this package is Org 9.6, so both spellings have to be reachable.

(defun orgacle--link-preview-refresh ()
  "Regenerate the inline image previews in the current buffer."
  (if (fboundp 'org-link-preview-refresh)
      (org-link-preview-refresh)
    (with-no-warnings (org-redisplay-inline-images))))

(defun orgacle--link-preview-clear ()
  "Remove the inline image previews from the current buffer."
  (if (fboundp 'org-link-preview-clear)
      (org-link-preview-clear)
    (with-no-warnings (org-remove-inline-images))))

;; These exist only on X11 builds, where term/x-win.el defines them.  A
;; value-less `defvar' only quiets the byte-compiler within the file it
;; appears in -- unlike a `defvar' with a value, it has no effect at
;; load time and does not carry to a file that merely requires this
;; one -- so any other file that sets one of these would need its own
;; copy of the relevant line; every use site of all four is confined to
;; this file as of this writing.  The `boundp' guards at each use site
;; are what decide anything at runtime.
(defvar x-pointer-dot)
(defvar x-pointer-shape)
(defvar x-pointer-invisible)
(defvar x-sensitive-text-pointer-shape)

(defgroup orgacle nil
  "This is a presentation mode for Emacs."
  :group 'orgacle)

(defface orgacle-title-face
  '((t :weight bold :height 360 :underline t :inherit variable-pitch))
  "Face used for the title of the document during the presentation."
  :group 'orgacle)
(defface orgacle-heading-face
  '((t :weight bold :height 270 :underline t :inherit variable-pitch))
  "Face used for the top-level headings in the outline during the presentation."
  :group 'orgacle)
(defface orgacle-subheading-face
  '((t :weight bold :height 240 :inherit variable-pitch))
  "Face used for any non-top-level headings in the outline during the presentation."
  :group 'orgacle)
(defface orgacle-author-face
  '((t :height 1.6 :inherit variable-pitch))
  "Face used for the author of the document during the presentation."
  :group 'orgacle)
(defface orgacle-bullet-face
  '((t :weight bold :height 1.4 :underline nil :inherit variable-pitch))
  "Face used for bullets during the presentation."
  :group 'orgacle)
(defface orgacle-hidden-face
  '((t))
  "Unused; hiding is done with the `invisible' text property instead.
`:invisible' was never a real face attribute, and current Emacs
rejects it at compile time.  This face is not applied anywhere in the
file; it is kept only because removing it would be a public API
change, which is out of scope here."
  :group 'orgacle)
(defface orgacle-timer-warning-face
  '((t :foreground "orange" :weight bold))
  "Face for the talk timer once elapsed time nears the target duration.
Applied by `orgacle--timer-string' once elapsed time reaches 90% of the
target `orgacle--duration' returns, and up until the target itself, at
which point `orgacle-timer-overtime-face' takes over instead."
  :group 'orgacle)
(defface orgacle-timer-overtime-face
  '((t :foreground "red" :weight bold))
  "Face for the talk timer once elapsed time reaches the target duration.
Applied by `orgacle--timer-string' once elapsed time reaches or exceeds
the target `orgacle--duration' returns."
  :group 'orgacle)

(defcustom orgacle-indicators t
  "Whether to display fringe indicators for extra content on a slide.
When non-nil, a black square appears in the right fringe if the
current page has an ORGACLE_SHOW_FILE property, and an empty square
if it has an ORGACLE_SHOW_VIDEO property.  When showing PDF files,
an arrow in the right fringe indicates that there are more pages to
show."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-slide-in nil
  "Whether to apply a slide-in effect when changing slides, by default.
A heading's ORGACLE_SLIDE_IN property overrides this default for that
one slide: a value of \\='no\\=', \\='nil\\=' or \\='off\\=' turns the
animation off, and any other value turns it on, regardless of this
variable's setting.  See `orgacle--slide-in-p'."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-slide-in-lines 10
  "Number of lines below the header used for the slide-in animation.
Only relevant when `orgacle-slide-in' is enabled."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-slide-in-duration 0.250
  "When slide-in is used, duration of the effect, in seconds."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-slide-in-pause 1
  "Pause after changing slide, before the slide-in kicks in."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-text-scale 400
  "Height for the text size when presenting."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-format-latex-scale 4
  "A scaling factor for the size of the images generated from LaTeX."
  :type 'number
  :group 'orgacle)

(defcustom orgacle-hide-todos t
  "Whether or not to hide TODOs during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-hide-tags t
  "Whether or not to hide tags during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-hide-properties t
  "Whether or not to hide properties during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-mode-line '(:eval (orgacle--default-mode-line))
  "Mode-line construct to use during the presentation, or nil to hide it.
The default shows the page number and, once `orgacle--timer-string' has
something to show, the talk timer beside it; see
`orgacle--default-mode-line'.  Set this to any other mode-line construct
to replace that entirely -- a fully custom value here is returned
exactly as set, never augmented with the timer -- or set nil to hide
the mode line altogether.  A single file overrides whatever this holds
with its own #+ORGACLE_MODE_LINE: keyword; see `orgacle-get-mode-line'."
  :type 'sexp
  :group 'orgacle)

(defcustom orgacle-src-blocks-visible t
  "If non-nil source blocks are initially visible on slide change.
If nil then source blocks are initially hidden on slide change."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-use-org-superstar t
  "Whether to prettify bullets with `org-superstar-mode'.
Has no effect when the `org-superstar' package is not installed."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-start-presentation-hook nil
  "Hook run after starting a presentation."
  :type 'hook
  :group 'orgacle)

(defcustom orgacle-stop-presentation-hook nil
  "Hook run before stopping a presentation."
  :type 'hook
  :group 'orgacle)

(defcustom orgacle-x-pointer-shape (and (boundp 'x-pointer-dot) x-pointer-dot)
  "Shape of the mouse pointer during the presentation.
The value is one of the `x-pointer-' constants, which are integers, or
nil to leave the pointer unchanged.  Those constants exist only on X11
builds, so this is nil elsewhere."
  :type '(choice (const :tag "Leave unchanged" nil) integer)
  :group 'orgacle)

(defcustom orgacle-tooltip-mode nil
  "Whether tooltips are shown during the presentation."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-internal-border-width 75
  "Border width, in pixels, around the presented material.
Passed straight through to `make-frame' as the presentation frame's
own `internal-border-width' parameter, so it takes effect once, when
the frame is created; changing it while a presentation is already
running has no effect on that frame.  Defaults to 75, matching the
hardcoded value every presentation used before this variable was wired
in, so wiring it in changes no existing user's display until they
actually customize it."
  :type 'integer
  :group 'orgacle)

(defcustom orgacle-speaker-notes t
  "Whether to collect speaker notes into an *Orgacle Notes* buffer.
The buffer is shown in its own frame, which can be moved to a second
screen, and follows the slide being presented."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-presenter-view t
  "Whether the speaker-notes buffer shows a presenter-console header.
The header names the current slide's position as N/M, the following
slide's title, and the talk timer, via `orgacle--presenter-header';
see that function for exactly what appears.  It lives in the notes
buffer's `header-line-format', not in its text, so turning this off
leaves that buffer's contents exactly as they were before this option
existed.  Only takes effect the next time `orgacle--build-notes-buffer'
runs -- the same as `orgacle-speaker-notes' itself -- so toggling it
mid-presentation has no effect until the notes buffer is next rebuilt,
for example by `orgacle-refresh'.  Has no effect at all when
`orgacle-speaker-notes' is nil, since there is then no notes buffer for
a header to appear in."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-wpm 150
  "Words-per-minute factor used to estimate a presentation's speaking time."
  :type 'integer
  :group 'orgacle)

(defcustom orgacle-duration nil
  "Target length of the presentation, in minutes, or nil for no target.
A single file overrides this with its own #+ORGACLE_DURATION: keyword;
see `orgacle--duration'.  Also controls whether the mode-line timer
appears at all: with no target, `orgacle--timer-string' is the empty
string, exactly as if no timer feature existed; with a target set, it
shows elapsed time against it and changes face as the target approaches
and passes.  There is no way to show elapsed time alone without a
target -- set a generous one instead."
  :type '(choice (const :tag "No target duration" nil) integer)
  :group 'orgacle)

(defcustom orgacle-reveal-on-navigation t
  "Whether `n' and `p' also drive a slide's incremental reveal.
Non-nil (the default): while the current slide has reveal targets left
-- see `orgacle--reveal-targets' -- `orgacle-next-page' reveals the
next one instead of moving to the next slide, and `orgacle-previous-page'
hides the last-revealed one again instead of moving to the previous
slide; once the slide's reveal is exhausted, or on a slide with no
reveal targets at all, `n' and `p' change slide exactly as they always
have.  With this nil, `n' and `p' always change slide immediately,
regardless of any unrevealed targets, and reveal is only reachable on
its own keys, `N' and `P' (`orgacle-reveal-next' and
`orgacle-reveal-previous'), which work the same way whichever way this
option is set."
  :type 'boolean
  :group 'orgacle)

(defcustom orgacle-video-player "mplayer"
  "Program used to play videos; see `orgacle-show-video'.
Supported players are \"mplayer\" and \"vlc\"."
  :type 'string
  :group 'orgacle)

(cl-defstruct (orgacle--session (:constructor orgacle--session-create))
  "The state one running presentation keeps.
Slots replace what used to be individually loose `defvar' forms: the
presentation frame, the original Org buffer and its restriction, the
temporary file used for a narrowed presentation, the slide vector and
the index into it, the speaker-notes buffer and its marker vector, the
auxiliary and presentation windows, the time the presentation started,
and the current slide's incremental-reveal state.
`orgacle--session-ensure' is almost always the right way to reach a
slot; see its docstring for why.

The index slot defaults to 0, not nil: `orgacle-next-page' and
`orgacle-previous-page' do arithmetic directly on this slot -- (1+
...) and (1- ...) -- before `orgacle--start-slides' has necessarily
run, for example when a fresh session is auto-vivified by
`orgacle--session-ensure' on `M-x orgacle-next-page' with nothing
running, or after `orgacle-quit' set `orgacle--session' back to nil.
Leaving the slot without a default made that arithmetic (1+ nil),
which signals `wrong-type-argument'; `orgacle-jump-to-page' was immune
only because it computes from its own argument instead of this slot.

The start-time slot, by contrast, has no default and stays nil until
`orgacle-run' sets it with `float-time': a session auto-vivified by
`orgacle--session-ensure' before a presentation has actually started
has nothing to measure elapsed time from, and `orgacle--elapsed' treats
a nil start-time as zero elapsed seconds rather than signalling.

The three reveal-* slots hold `orgacle-reveal.el's per-presentation
state: reveal-overlays (a vector, or nil for a slide with no reveal
targets), reveal-index (defaulting to 0, for the same
arithmetic-before-`orgacle--start-slides' reason as the index slot
above), and reveal-enter-revealed (a one-shot flag `orgacle-previous-page'
sets before stepping back onto a slide it wants to land fully
revealed, that `orgacle-reveal-reset' reads once and clears).  These
used to be plain variables; moving them here means a session
auto-vivified fresh by `orgacle--session-ensure' -- because
`orgacle--session' was nil, the same auto-vivification the index slot's
own paragraph above describes -- carries no reveal state left over
from whatever ran before it, by construction, the same way its slides
slot starts empty rather than pointing at a previous presentation's
markers.  This closed a real defect: with `orgacle--session' nil and a
killed presented buffer, `orgacle-next-page' used to consult
leftover, no-longer-meaningful reveal overlays from before the reset,
`overlay-put' a dead one -- a silent no-op -- and report that it had
moved, swallowing the keypress instead of changing slide."
  frame org-buffer org-restriction org-file
  slides (index 0) notes-buffer notes-markers
  aux-window presentation-window start-time
  reveal-overlays (reveal-index 0) reveal-enter-revealed)

(defvar orgacle--session nil
  "The running presentation, or nil when none is running.
An `orgacle--session' struct once a presentation exists; nil before
the first `orgacle-run' and again after every `orgacle-quit'.
`orgacle-run' replaces this with a fresh session on every call rather
than mutating whatever is already here, so a presentation whose frame
was killed without going through `orgacle-quit' cannot leave stale
state -- for example a narrowed `org-restriction' slot -- for the next
presentation to inherit.")

(defun orgacle--session-ensure ()
  "Return `orgacle--session', creating one first when it is nil.
Several functions that read or write session state -- slide
navigation, notes positioning, building the notes buffer, and more --
are also called directly by the test suite and can run before
`orgacle-run' has started a presentation.  Auto-vivifying here, rather
than guarding every read and write site against a nil session, is what
lets those call sites look like an ordinary accessor call regardless of
whether a presentation is actually running."
  (or orgacle--session (setq orgacle--session (orgacle--session-create))))

(defconst orgacle-saved-variables
  '(org-src-fontify-natively
    org-hide-emphasis-markers
    org-pretty-entities
    org-fontify-quote-and-verse-blocks)
  "Variables Orgacle changes while presenting and restores on quit.
Adding one here is enough; both directions are handled by
`orgacle--save-user-state' and `orgacle--restore-user-state'.")

(defvar orgacle--saved-state nil
  "Alist of (SYMBOL . VALUE) captured by `orgacle--save-user-state'.
Also doubles as the \"is a save already pending\" flag that function
tests before it does anything, so its own value is what makes the
guard live again once `orgacle--restore-user-state' clears it back to
nil.")

(defvar orgacle-outline-ellipsis nil
  "The `selective-display' display-table slot, saved while presenting.
This holds a display-table value, not an ordinary variable, so it is
saved and restored directly with `display-table-slot' and
`set-display-table-slot' rather than through `orgacle-saved-variables';
see `orgacle--save-user-state', which guards it the same way.")

(defvar orgacle-user-tooltip-mode nil
  "Whether tooltips were on before the presentation started.
Saved by `orgacle--save-user-state', under the same re-entrancy guard
that protects `orgacle-saved-variables' and `orgacle-outline-ellipsis',
before `orgacle-run' sets `tooltip-mode' to `orgacle-tooltip-mode' for
the duration of the presentation; put back by `orgacle--restore-user-state',
which only runs when a save is actually pending, so a stray
`orgacle-quit' with nothing running leaves `tooltip-mode' alone instead
of forcing it off.  `tooltip-mode' is a global minor mode, not a plain
variable -- restoring it means calling the mode function again, so its
own setup and teardown run, rather than just `setq'ing the variable
back -- which is why it cannot join `orgacle-saved-variables' itself,
the same way `orgacle-user-x-pointer-shape', defined next, cannot: that
one is guarded by `(boundp \\='x-pointer-shape)' instead, since the X11
pointer constants this package touches do not exist on every build, and
capturing one with `symbol-value' the way `orgacle-saved-variables' does
would signal `void-variable' there.")

(defvar orgacle-user-x-pointer-shape nil
  "The `x-pointer-shape' value before the presentation started.
Saved by `orgacle--save-user-state' and put back by
`orgacle--restore-user-state', under the same re-entrancy guard as
`orgacle-user-tooltip-mode' -- see its docstring for why this cannot
join `orgacle-saved-variables' -- so that a stray `orgacle-quit' with
nothing running leaves the pointer alone instead of overwriting it with
this variable's default of nil, which used to be exactly the bug the
`tooltip-mode' and outline-ellipsis guards were already added to fix
elsewhere.  Read or written only when `(boundp \\='x-pointer-shape)' is
non-nil: those constants exist only on X11 builds.")

(defvar orgacle-user-x-sensitive-text-pointer-shape nil
  "The `x-sensitive-text-pointer-shape' value before the presentation started.
Companion to `orgacle-user-x-pointer-shape'; see that variable's
docstring for the guard and re-entrancy behaviour both share.")

(defvar orgacle-user-void-text-area-pointer nil
  "The `void-text-area-pointer' value before the presentation started.
Saved and restored alongside `orgacle-user-x-pointer-shape', under the
same guard and for the same reason.  Unlike the X pointer-shape
variables, `void-text-area-pointer' is an ordinary variable on every
build, not an X11-only one, but this package only ever changes it
inside the same `(boundp \\='x-pointer-shape)' block that changes the
pointer shapes, so it is captured and restored there too, under that
same condition, rather than unconditionally.")

(defun orgacle--save-user-state ()
  "Record the user's state, once, until it is restored.
Captures the current value of every variable in
`orgacle-saved-variables', plus the outline-ellipsis display-table
slot into `orgacle-outline-ellipsis', whether tooltips were on into
`orgacle-user-tooltip-mode', and -- only when `(boundp \\='x-pointer-shape)'
-- the prior X pointer shapes and `void-text-area-pointer' into
`orgacle-user-x-pointer-shape', `orgacle-user-x-sensitive-text-pointer-shape'
and `orgacle-user-void-text-area-pointer'.  None of these four can join
that list; see `orgacle-user-tooltip-mode's docstring for why, in each
case.

A no-op when a save is already pending: `orgacle-mode' calls this
unconditionally on every entry, and entering it a second time with no
intervening `orgacle-quit' -- for example because the presentation
frame was killed with the window manager instead of `q', or because
`orgacle-run' was invoked from a second Org buffer, which only checks
the *current* buffer's major mode -- must not let the second entry's
save overwrite the user's original values with the presentation's own.
The first save wins; `orgacle--restore-user-state' is what clears
`orgacle--saved-state' back to nil, making the guard live again for the
next genuine entry.  Since `orgacle-run' toggles `tooltip-mode' to
`orgacle-tooltip-mode' only after calling `orgacle-mode', capturing
`tooltip-mode' here, under the same guard, always sees the user's true
prior setting rather than a presentation's own; likewise, `orgacle-run'
calls this function before `orgacle--get-frame' sets the pointer to the
presentation's own shape, so the X pointer capture here always sees the
user's true prior setting too, not the presentation's.

`standard-display-table' is nil until something creates it, which the
autoloaded `disp-table.el' normally does as a side effect of its own
loading; under byte-compiled evaluation that has not always happened
yet, so this vivifies it directly first, using the same idiom
`disp-table.el' itself uses."
  (unless orgacle--saved-state
    (setq orgacle--saved-state
          (mapcar (lambda (sym) (cons sym (symbol-value sym)))
                  orgacle-saved-variables))
    (unless (char-table-p standard-display-table)
      (setq standard-display-table (make-display-table)))
    (setq orgacle-outline-ellipsis
          (display-table-slot standard-display-table 'selective-display))
    (setq orgacle-user-tooltip-mode tooltip-mode)
    (when (boundp 'x-pointer-shape)
      (setq orgacle-user-x-pointer-shape x-pointer-shape)
      (setq orgacle-user-x-sensitive-text-pointer-shape
            x-sensitive-text-pointer-shape)
      (setq orgacle-user-void-text-area-pointer void-text-area-pointer))))

(defun orgacle--restore-user-state ()
  "Put back everything saved by `orgacle--save-user-state'.
Restores every variable in `orgacle-saved-variables' and, when a save
is actually pending -- guarding on `orgacle--saved-state' the same way
`orgacle--save-user-state' does, so this stays a no-op when nothing has
been saved and is safe to call even when no presentation is running,
including twice in a row -- also puts `tooltip-mode' back by calling
the mode function again, since restoring a global minor mode correctly
means running its own setup or teardown, not just `setq'ing the
variable; puts the outline-ellipsis display-table slot back; and, only
when `(boundp \\='x-pointer-shape)', puts the X pointer shapes and
`void-text-area-pointer' back too, then applies the restored shapes by
setting the mouse colour to its own current value, the same trick
`orgacle--get-frame' and `orgacle-toggle-mouse' use.
Without that guard, calling this with nothing saved would
unconditionally turn tooltips off, because `orgacle-user-tooltip-mode'
defaults to nil; would unconditionally overwrite the `selective-display'
slot of `standard-display-table' with `orgacle-outline-ellipsis' -- nil
by default -- whenever that table happens to already exist, clobbering
a slot some other package or the user set; and would unconditionally
overwrite the X pointer shapes and `void-text-area-pointer' with these
variables' nil defaults -- discarding a `void-text-area-pointer'
customization silently -- and apply that to the mouse pointer on the
*selected* frame, even though no Orgacle save ever ran to justify
touching any of it.  This was the last instance of exactly that bug
class in the package, after the `tooltip-mode' and outline-ellipsis
fixes above.

The `char-table-p' check on `standard-display-table' guards a
byte-compilation-only hazard, not the same-shape problem above:
`orgacle--save-user-state' vivifies the table as part of the very same
guarded block that sets `orgacle-outline-ellipsis', so by the time
`orgacle--saved-state' is non-nil the table is already guaranteed to be
a real char-table; the check stays anyway, since under byte-compiled
evaluation `set-display-table-slot's first-ever call in a process
evaluates a nil DISPLAY-TABLE argument before the autoloaded
`disp-table.el' has a chance to auto-vivify it, and signals
`wrong-type-argument' instead."
  (when orgacle--saved-state
    (tooltip-mode (if orgacle-user-tooltip-mode 1 -1))
    (when (char-table-p standard-display-table)
      (set-display-table-slot standard-display-table
                              'selective-display orgacle-outline-ellipsis))
    (when (boundp 'x-pointer-shape)
      (setq x-pointer-shape orgacle-user-x-pointer-shape)
      (setq x-sensitive-text-pointer-shape
            orgacle-user-x-sensitive-text-pointer-shape)
      (setq void-text-area-pointer orgacle-user-void-text-area-pointer)
      ;; setting the mouse colour to its current value applies the shapes
      (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters))))))
  (dolist (entry orgacle--saved-state)
    (set (car entry) (cdr entry)))
  (setq orgacle--saved-state nil))

(defvar orgacle-overlays nil)
(defvar orgacle-fringe-overlays nil)
(defvar orgacle-aux-fringe-overlay nil)
(defvar orgacle-page-number 0
  "Number of the slide currently on display, counting from 1.
Always kept equal to the running session's index slot plus one; the
mode line reads this variable, and a user may too, which is why it
stays a variable of its own instead of being computed on every read.
`orgacle--sync-page-number' is the sole place that sets it, called from
`orgacle--start-slides', `orgacle--goto-slide' and `orgacle-refresh'.")

(defvar orgacle-mouse-visible t
  "Whether the mouse pointer is currently requested visible.
`orgacle-toggle-mouse' flips this on every call, before it looks at the
old value to decide which pointer shape to apply, so the two directions
alternate correctly instead of the toggle only ever hiding the pointer.
This is updated unconditionally, even on a build without X11 pointer
support, since it records what was *requested* rather than the X
pointer state itself; only applying that request to the actual pointer
needs `x-pointer-shape' to be bound.  `orgacle--get-frame' also resets
this to t every time it forces the pointer visible, which keeps a
leftover nil from a previous, already-quit presentation's `m' press
from disagreeing with the next presentation's actual, always-visible
starting state.")

(defvar orgacle-frame-level 1)

(defvar orgacle-src-block-toggle-state nil)

(defvar orgacle-show-filename nil
  "Filename shown in the auxiliary window.
See `orgacle-show-file'.")

(defvar orgacle-show-buffer nil)

(defvar orgacle--pdf-tools-warned nil
  "Non-nil once `orgacle-show-file' has warned that pdf-tools is absent.
Keeps that warning to once per session instead of once per slide.")

(defun orgacle-get-frame-level ()
  "Get the heading level to show as different frames."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_FRAME_LEVEL:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (string-to-number (match-string 1))
        orgacle-frame-level))))

(defun orgacle-get-mode-line ()
  "Get the presentation-specific mode-line."
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_MODE_LINE:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (car (read-from-string (match-string 1)))
        orgacle-mode-line))))

(defun orgacle--duration ()
  "Return this buffer's target duration in minutes, or nil for none.
Reads #+ORGACLE_DURATION: if present, the same way `orgacle-get-frame-level'
and `orgacle-get-mode-line' read their own keywords; falls back to
`orgacle-duration' otherwise."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (if (re-search-forward
           "^#\\+ORGACLE_DURATION:[ \t]*\\(.*?\\)[ \t]*$" nil t)
          (string-to-number (match-string 1))
        orgacle-duration))))

(defun orgacle--elapsed (&optional now)
  "Return whole seconds elapsed since the running session started.
Zero when the session's start-time slot is nil, which is the case for a
session `orgacle--session-ensure' auto-vivifies before `orgacle-run' has
actually started a presentation.  NOW, when given, replaces the actual
current time (what `float-time' would return); the test suite passes a
fixed value here instead of sleeping, which would make elapsed-time
tests slow and their exact assertions flaky."
  (let ((start (orgacle--session-start-time (orgacle--session-ensure))))
    (if start
        (round (- (or now (float-time)) start))
      0)))

(defun orgacle--format-mmss (seconds)
  "Format SECONDS as a MINUTES:SS string for the mode line.
Minutes are neither padded nor wrapped at 60: a 75-minute talk reads
\"75:00\", not \"1:15:00\".  This is deliberate, not an oversight -- the
number a presenter actually wants mid-talk is minutes elapsed, and the
hour:minute:second form invites misreading \"1:15:00\" as one minute
fifteen.  Seconds are always two digits."
  (format "%d:%02d" (/ seconds 60) (mod seconds 60)))

(defun orgacle--timer-string ()
  "Return the running presentation's timer as a mode-line string.
Empty both when no presentation is running (`orgacle--session' is nil)
and when `orgacle--duration' returns no target for this buffer: with
nothing to measure against, a bare elapsed count is not very
actionable -- \"7:42\" says little, \"7:42/20:00\" says where the
presenter stands -- and the phase's \"off by default\" rule means a
presenter who never set a target should not see a clock appear that
they never asked for.  Set `orgacle-duration' (or #+ORGACLE_DURATION:)
to get a timer at all; a generous value with no real deadline gets an
effectively elapsed-only display deliberately, rather than this
function growing a second, target-less display mode of its own.
Otherwise shows ELAPSED/TARGET, both from `orgacle--elapsed' and
`orgacle--duration' as MINUTES:SS, propertized with
`orgacle-timer-warning-face' once elapsed time reaches 90% of the
target and with `orgacle-timer-overtime-face' once it reaches the
target itself, so a presenter sees the timer change colour without
doing the arithmetic themselves."
  (if (or (null orgacle--session) (null (orgacle--duration)))
      ""
    (let* ((elapsed (orgacle--elapsed))
           (target (orgacle--duration))
           (string (format "%s/%s"
                           (orgacle--format-mmss elapsed)
                           (orgacle--format-mmss (* target 60)))))
      (cond
       ;; target * 60 * 9 compares against elapsed * 10 rather than
       ;; dividing, so this never risks a float rounding the boundary
       ;; the wrong way, and never divides by a zero-minute target.
       ((>= elapsed (* target 60))
        (propertize string 'face 'orgacle-timer-overtime-face))
       ((>= (* elapsed 10) (* target 60 9))
        (propertize string 'face 'orgacle-timer-warning-face))
       (t string)))))

(defun orgacle--default-mode-line ()
  "Default mode-line construct: the page number plus the timer.
`orgacle-mode-line' defaults to `(:eval (orgacle--default-mode-line))',
so this is what a presenter sees unless they have replaced that
defcustom or set #+ORGACLE_MODE_LINE: in the file being presented, in
which case neither this function nor `orgacle--timer-string' is ever
called; see `orgacle-get-mode-line'.  `orgacle--timer-string' is empty
whenever `orgacle--session' is nil or `orgacle--duration' has no
target, so this reduces to the page number alone outside of a
presentation, and stays that way through an entire presentation for
which no target duration was ever configured -- exactly how
`orgacle-mode-line' behaved before the timer existed, in both cases."
  (let ((timer (orgacle--timer-string)))
    (if (string= timer "")
        (int-to-string orgacle-page-number)
      (concat (int-to-string orgacle-page-number) "  " timer))))

(defun orgacle--slide-p ()
  "Return non-nil when point is on a heading that is its own slide.
A slide is a heading at `orgacle-frame-level' that is not a title
page, not a speaker-notes subtree, and does not carry ORGACLE_HIDE."
  (and (org-at-heading-p)
       (= (org-reduced-level (org-current-level)) orgacle-frame-level)
       (not (org-entry-get nil "ORGACLE_HIDE"))
       (let ((title (downcase (or (org-entry-get nil "ITEM") ""))))
         (not (member title '("title page" "speaker notes"))))))

(defun orgacle--build-slides ()
  "Return a vector of markers, one per slide, in buffer order.
Works on the whole buffer even when called with the buffer narrowed
to a single slide, which is the state during a presentation.

Each marker has insertion type t (advancing), the same choice
`org-agenda-new-marker' makes for markers that identify a heading: a
marker at a heading's bol is exactly the position where a new sibling
heading gets inserted -- for example \\='M-RET\\=' at the start of a
heading line, which prepends a new heading text ending in a newline
right there.  A non-advancing marker (the default) would stay behind,
now pointing at that newly-inserted heading instead of the one it was
built for; an advancing marker moves forward with its own heading's
text and keeps pointing at it."
  (let (slides)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward org-outline-regexp-bol nil t)
          (beginning-of-line)
          (when (orgacle--slide-p)
            (push (copy-marker (point) t) slides))
          (end-of-line))))
    (vconcat (nreverse slides))))

(defun orgacle--slide-index-at-point (&optional pos)
  "Return the index into the session's slides slot of the slide at or before POS.
POS defaults to point.  Used to re-derive the session's index slot
after an edit may have changed which headings are slides -- adding or
removing a heading, or changing whether an existing one qualifies as
`orgacle--slide-p' -- so that navigation reflects where point actually
is rather than a position recorded before the edit.  Returns 0 when
POS precedes every slide, or when the slides slot is empty (in the
latter case the return value is meaningless; callers must check
emptiness separately, the same way `orgacle--goto-slide' does)."
  (let ((pos (or pos (point))) (index 0)
        (slides (orgacle--session-slides (orgacle--session-ensure))))
    (dotimes (i (length slides))
      (when (<= (aref slides i) pos)
        (setq index i)))
    index))

(defun orgacle--sync-page-number ()
  "Set `orgacle-page-number' from the running session's index slot.
Zero when the session's slides slot is empty, since there is then no
page to number; the index plus one otherwise.  This is the only place
that computes `orgacle-page-number', so every caller that changes the
index slot -- or rebuilds the slides slot out from under it, as
`orgacle-refresh' does -- gets a consistent page number without having
to remember the empty-deck special case itself."
  (let ((session (orgacle--session-ensure)))
    (setq orgacle-page-number
          (if (> (length (orgacle--session-slides session)) 0)
              (1+ (orgacle--session-index session))
            0))))

(defun orgacle--get-frame ()
  "Create and set up the Orgacle frame.
Always forces the mouse pointer visible, resetting `orgacle-mouse-visible'
to t to match: a presentation's frame starts with the pointer shown
regardless of whatever `orgacle-toggle-mouse' left that variable at in
a previous, already-quit presentation, and without this reset the two
could disagree across a quit/re-run, making the next `m' press in the
new presentation silently apply a shape the pointer already has."
  (let ((session (orgacle--session-ensure)))
    (unless (frame-live-p (orgacle--session-frame session))
      (setf (orgacle--session-frame session)
            (make-frame `((minibuffer . nil)
                          (title . "Orgacle")
                          (fullscreen . fullboth)
                          (menu-bar-lines . 0)
                          (tool-bar-lines . 0)
                          (vertical-scroll-bars . nil)
                          (left-fringe . 0)
                          (right-fringe . 40)
                          (right-divider-width . 0)
                          (cursor-type . nil)
                          (internal-border-width . ,orgacle-internal-border-width)))))
    (raise-frame (orgacle--session-frame session))
    (select-frame-set-input-focus (orgacle--session-frame session))
    ;; set fringe background to same as frame background, on this frame
    ;; only -- omitting FRAME here would rewrite the `fringe' face for
    ;; every frame, including ones no presentation ever touched
    (set-face-background 'fringe (cdr (assoc 'background-color (frame-parameters)))
                         (orgacle--session-frame session))
    ;; keep the "requested" bookkeeping variable in sync with the pointer
    ;; this unconditionally forces visible below, so a leftover nil from a
    ;; previous, already-quit presentation's `m' press cannot make the next
    ;; presentation's first `m' press a silent no-op -- outside the
    ;; `(boundp 'x-pointer-shape)' guard below, because `orgacle-mouse-visible'
    ;; is a plain, always-bound variable that tracks the presenter's request
    ;; on every build, X11 or not, the same distinction `orgacle-toggle-mouse'
    ;; already draws between itself and the X11-only pointer variables
    (setq orgacle-mouse-visible t)
    ;; set mouse pointer shape for the presentation; `orgacle--save-user-state',
    ;; called by `orgacle-run' before this function, has already captured
    ;; the user's prior setting to restore on `orgacle-quit'
    (when (boundp 'x-pointer-shape)
      (setq x-pointer-shape orgacle-x-pointer-shape)
      (setq x-sensitive-text-pointer-shape orgacle-x-pointer-shape)
      (setq void-text-area-pointer 'text)
      ;; setting the mouse colour to its current value applies the shapes
      (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters)))))
    (orgacle--session-frame session)))

(defun orgacle-toggle-mouse ()
  "Show or hide the mouse pointer.
Flips `orgacle-mouse-visible' first, then applies the new request to
the actual pointer shape when `x-pointer-shape' is bound -- flipping
before applying, rather than after, is what makes repeated calls
actually alternate between hiding and showing instead of always taking
the same branch.  On a build without X11 pointer support, the request
is still recorded in `orgacle-mouse-visible', there is just nothing
further to apply it to."
  (interactive)
  (setq orgacle-mouse-visible (not orgacle-mouse-visible))
  (when (boundp 'x-pointer-shape)
    (if orgacle-mouse-visible
        (setq x-pointer-shape orgacle-x-pointer-shape
              x-sensitive-text-pointer-shape orgacle-x-pointer-shape)
      (setq x-pointer-shape x-pointer-invisible
            x-sensitive-text-pointer-shape x-pointer-invisible))
    (setq void-text-area-pointer 'text)
    ;; setting the mouse colour to its current value applies the shapes
    (set-mouse-color (cdr (assoc 'mouse-color (frame-parameters))))))

(defun orgacle-clean-overlays (&optional start end)
  "Delete the overlays in `orgacle-overlays' contained in START..END.
An overlay that starts before START or ends after END is kept rather
than deleted.  With START and END both nil, every overlay in
`orgacle-overlays' is deleted."
  (interactive)
  (let (kept)
    (dolist (ov orgacle-overlays)
      (if (or (and start (overlay-start ov) (<= (overlay-start ov) start))
              (and end   (overlay-end   ov) (>= (overlay-end   ov) end)))
          (push ov kept)
        (delete-overlay ov)))
    (setq orgacle-overlays kept)))

(defun orgacle-clean-fringe-overlays ()
  "Remove file and video indicators from fringe."
  (interactive)
  (dolist (ov orgacle-fringe-overlays)
    (delete-overlay ov))
  (setq orgacle-fringe-overlays nil))

(defvar orgacle-page-hook nil
  "Hook run after a slide has been displayed and narrowed.
Each feature module adds its own function here, so that displaying a
slide does not have to know which subsystems exist.  A member takes no
arguments.  Order is significant: file-before-indicators is the
invariant that matters, because `orgacle-show-file' clears the fringe
overlays that `orgacle-show-indicators-maybe' draws, so running them
the other way round loses the indicators; see the `add-hook' calls in
orgacle-fontify.el, orgacle-media.el and orgacle-notes.el for how the
full default order is kept.  Members run wrapped in
`save-current-buffer', `save-selected-window' and a `condition-case':
a member may freely change the current buffer or selected window (for
example to visit a file in another window), but on both success and
failure the next member sees the buffer and window this one started
with; a failure is logged and does not stop the remaining members,
because nothing should be able to end a presentation mid-talk.")

(defconst orgacle--log-buffer-name "*Orgacle Log*"
  "Name of the buffer that records a failing `orgacle-page-hook' member.
Created on first use by `orgacle--log-page-hook-failure'.  Never
displayed by Orgacle itself -- read it afterwards with `switch-to-buffer'
or similar; a window appearing mid-presentation to announce a failure
would be worse than the failure it reports.")

(defun orgacle--log-page-hook-failure (fn err)
  "Append a note that FN signalled ERR to `orgacle--log-buffer-name'.
FN is the page-hook member `orgacle--run-page-hook' was calling and ERR
the error its `condition-case' caught.  The entry also carries the
running session's slide number, read fresh via `orgacle--session-ensure',
so a presenter reading the log after the talk knows which slide broke --
the 1-based number every other presenter-facing surface uses, the same
as `orgacle-page-number' and what `orgacle-jump-to-page' takes, not the
0-based index slot itself; a log that instead read \"slide 1\" for the
second slide would disagree with everything else the presenter saw
on screen.  Left as \"unknown\" rather than signalling or guessing when
nothing has built a slide deck yet, which happens in tests that call
`orgacle--run-page-hook' without first calling `orgacle--start-slides'.

No true backtrace: by the time this function runs, the `condition-case'
in `orgacle--run-page-hook' has already unwound the stack that ERR was
signalled from, so there is nothing of the original call left to walk;
capturing frames from inside this handler would only describe this
handler, not the failure.  Producing a real one needs either
`condition-case-unless-debug', which stops catching the error at all
and drops into the debugger instead whenever the presenter happens to
have `debug-on-error' set -- the opposite of surviving a failure
mid-talk -- or rebinding the global `debugger' function around every
hook member to intercept the error before it unwinds, which is
session-wide state to mutate on every single slide change for a
backtrace that `error-message-string' already mostly conveys.  Neither
is worth risking the one guarantee this mechanism exists for, so this
logs the function, the slide number and the error text only.

Deliberately has no `condition-case' of its own: `orgacle--run-page-hook'
wraps its call to this function in `ignore-errors', which is what keeps
a problem here -- an unwritable `orgacle--log-buffer-name', a disk
error, anything -- from turning a failing hook member into a failing
presentation; see that call site."
  (let* ((index (orgacle--session-index (orgacle--session-ensure)))
         (slide (if index (1+ index) "unknown")))
    (with-current-buffer (get-buffer-create orgacle--log-buffer-name)
      (goto-char (point-max))
      (insert (format "[%s] slide %s: %s failed: %s\n"
                       (format-time-string "%Y-%m-%d %H:%M:%S")
                       slide
                       (if (symbolp fn) fn "anonymous function")
                       (error-message-string err))))))

(defun orgacle--run-page-hook ()
  "Run `orgacle-page-hook', surviving a member that signals.
Uses `run-hook-wrapped' rather than `dolist': a plain `dolist' over the
hook variable mishandles the two other ways a hook value is normally
allowed to look besides a flat list of global functions.  A
buffer-local value added with the LOCAL argument of `add-hook' ends
with a trailing sentinel meaning \"also run the global value\";
`dolist' has no notion of that sentinel, so it tries to `funcall' it
and the global members are never reached.  A hook whose
value is a single function symbol, not a list, makes `dolist' signal
`wrong-type-argument' while walking it, before the loop body's
`condition-case' is even reached, so the error is not contained and
escapes this function instead of being logged.  `run-hook-wrapped'
is the standard primitive for exactly this shape of variable, and
handles both cases correctly.

Each member additionally runs inside `save-current-buffer' and
`save-selected-window', so that a member which changes the buffer or
selected window and then signals (for example `orgacle-show-file',
which only re-selects the presentation window on its last line)
cannot hand the wrong buffer or window to the members that run after
it.  A failing member is reported in the echo area immediately, via
`message', and logged to `orgacle--log-buffer-name' for after the talk,
via `orgacle--log-page-hook-failure'; an anonymous function is named
generically rather than `%s'-formatted, since that would print its
whole byte-code object.  The logging call is wrapped in `ignore-errors'
so that a problem while logging -- as opposed to the original failure
being logged -- can never itself stop the remaining hook members from
running."
  (run-hook-wrapped
   'orgacle-page-hook
   (lambda (fn)
     (save-current-buffer
       (save-selected-window
         (condition-case err
             (funcall fn)
           (error
            (message "Orgacle: %s failed: %s"
                     (if (symbolp fn) fn "anonymous function")
                     (error-message-string err))
            (ignore-errors (orgacle--log-page-hook-failure fn err))))))
     nil)))

(provide 'orgacle-core)
;;; orgacle-core.el ends here
