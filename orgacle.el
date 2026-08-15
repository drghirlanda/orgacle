;;; orgacle.el --- Present Org-mode files as slide shows  -*- lexical-binding: t; -*-

;; Copyright (C) 2008 Tom Tromey <tromey@redhat.com>
;;               2010 Eric Schulte <schulte.eric@gmail.com>
;;               2020 Stefano Ghirlanda <drghirlanda@gmail.com>

;; Author: Tom Tromey <tromey@redhat.com>
;;         Phil Hagelberg <technomancy@gmail.com>
;;         Eric Schulte <schulte.eric@gmail.com>
;;         Puneeth Chaganti <punchagan@gmail.com>
;;         Lee Hinman <lee@writequit.org>
;;         Stefano Ghirlanda <drghirlanda@gmail.com>
;; Maintainer: Stefano Ghirlanda <drghirlanda@gmail.com>
;; URL: https://github.com/drghirlanda/orgacle
;; Created: 12 Jun 2008
;; Version: 2.0.0
;; Keywords: outlines, hypermedia, multimedia
;; Package-Requires: ((emacs "29.1"))

;; This file is not (yet) part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This is a presentation mode for Emacs.

;; To use, invoke `orgacle-run' in an `org-mode' buffer.  This will
;; make a full-screen frame special key bindings and features for
;; presentation.  Use n/p to navigate, or q to quit.  Read below for
;; more key bindings.  Each top-level headline becomes a frame in the
;; presentation (configure `ORGACLE_FRAME_LEVEL' to change this
;; default).  Org-mode markup is used to nicely display the buffer's
;; contents.

;; Orgacle began as a fork of epresent, by Tom Tromey, Phil Hagelberg,
;; Eric Schulte, Puneeth Chaganti and Lee Hinman, which has been
;; unmaintained since 2016.  Presentations written for the old package
;; use EPRESENT_ property names; `orgacle-migrate-buffer' converts them.

;;; Code:
(require 'org)
(require 'cl-lib)
(require 'org-superstar nil t)
(require 'orgacle-core)
(require 'orgacle-nav)
(require 'orgacle-fontify)
(require 'orgacle-src)
(require 'orgacle-media)
(require 'orgacle-notes)
;; Required after orgacle-fontify and orgacle-media specifically -- the
;; fourth of the five files that register a page-hook member here
;; (fifth of the six members themselves, after slide-in, show-file-auto,
;; show-indicators-maybe and position-notes -- F5, fix round 1:
;; corrected from "the fourth of six", which was wrong under both a
;; files reading and a members reading), though only the first two are
;; load-bearing -- so that orgacle-reveal.el's own prepending `add-hook'
;; call runs after `orgacle-slide-in-effect's and `orgacle-show-file-auto's,
;; the only other two page-hook members that also prepend, and so
;; lands ahead of both in the real, default `orgacle-page-hook'; see
;; orgacle-reveal.el's own `add-hook' comment for why reveal has to run
;; before slide-in specifically.
(require 'orgacle-reveal)
;; Required last of the five files that register a page-hook member,
;; contributing the sixth and last member itself, for the same
;; before-slide-in reason as orgacle-reveal.el immediately above; see
;; orgacle-appearance.el's own `add-hook' comment for why this position
;; is enough, and why its position relative to orgacle-reveal.el
;; specifically is a judgment call rather than a correctness dependency.
(require 'orgacle-appearance)
(require 'ox-orgacle)

;; `flyspell' is optional; the call site below is guarded by `fboundp'.
;; This declaration only quiets the byte-compiler.
(declare-function flyspell-mode-off "flyspell" ())

;; functions

(defun orgacle-quit ()
  "Quit the current presentation.
Safe to call when no presentation is running, and safe to call twice:
every step is guarded on the thing it acts on actually existing, and
the user's Org-mode variables, display-table slot, `tooltip-mode'
setting and X pointer state are restored in an `unwind-protect' cleanup
so a failure earlier in this function still restores them.  That same
cleanup discards `orgacle--session' unconditionally, so a failure
partway through this function still leaves no session behind for the
next `orgacle-run' to inherit stale state from -- for example a
narrowed `org-restriction' slot."
  (interactive)
  (let ((session orgacle--session))
    (unwind-protect
        (progn
          (run-hooks 'orgacle-stop-presentation-hook)
          ;; guarded on SESSION like every other step here: with no
          ;; presentation running, `M-x orgacle-quit' must not clear the
          ;; LaTeX preview overlays of whatever ordinary Org buffer
          ;; happens to be current
          (when session (org-clear-latex-preview))
          (remove-hook 'org-src-mode-hook 'orgacle-setup-src-edit)
          (remove-hook 'org-babel-after-execute-hook 'orgacle-refresh t)
          (when (and session (frame-live-p (orgacle--session-frame session)))
            (delete-frame (orgacle--session-frame session)))
          (when (and session (orgacle--session-org-file session))
            ;; P4 Task 6 fix round 1, Important 1.  The org-file slot
            ;; holds a filename relative to `default-directory' as it
            ;; stood when `org-org-export-to-org' produced it (see
            ;; `orgacle-test-run-quits-the-previous-sessions-temp-file's
            ;; own docstring in test/orgacle-test.el), not necessarily
            ;; this function's own `default-directory' when it runs --
            ;; and in the realistic case, where this function is called
            ;; from inside the very buffer it is about to kill (the
            ;; presenter is looking at the temp buffer and presses `q'),
            ;; killing it changes `current-buffer' to whatever Emacs
            ;; picks next, before the relative name below would have
            ;; been resolved.  Resolving it to an absolute path first,
            ;; via the temp buffer's own `buffer-file-name' -- which
            ;; Emacs always stores absolute, regardless of how the
            ;; buffer was visited -- fixes this independently of
            ;; whatever buffer ends up current afterward.  Confirmed
            ;; directly that the unfixed version leaves the temp file
            ;; on disk when this function is called from the presented
            ;; buffer itself, the ordinary way a presenter invokes it;
            ;; Step 3's own equivalent test happened to call this
            ;; function from a *different* buffer, which is why it did
            ;; not catch this.
            (let* ((buf (get-file-buffer (orgacle--session-org-file session)))
                   (file (or (and buf (buffer-file-name buf))
                             (expand-file-name (orgacle--session-org-file session)))))
              (when buf (kill-buffer buf))
              (when (file-exists-p file)
                (delete-file file))))
          (when (and session (buffer-live-p (orgacle--session-org-buffer session)))
            ;; P4 Task 6 fix round 1, Important 2.  Guarded on
            ;; `buffer-live-p', not merely non-nil: the org-buffer slot
            ;; holds a buffer *object*, which stays non-nil even after
            ;; the buffer it names has been killed independently of
            ;; this function -- for example by hand, or by some other
            ;; package -- and `set-buffer' on a dead buffer signals
            ;; `error', which nothing between here and this whole
            ;; `unwind-protect''s outer boundary catches.  That used to
            ;; abort every step below this one, including the
            ;; notes-buffer and its own frame's cleanup further down --
            ;; corrected here, fix round 2, Finding 6: the *presentation*
            ;; frame is deleted above this guard, not below it; only the
            ;; notes buffer and its frame are still ahead at this point
            ;; -- and left a following `orgacle-run' unable to complete
            ;; either: Step 3 made this function reachable from
            ;; `orgacle-run' itself when tearing down a previous session,
            ;; so an org-buffer
            ;; killed independently between two presentations now hard-
            ;; errors the *next* `orgacle-run' too, not merely a stray
            ;; `M-x orgacle-quit'.  Confirmed directly, both the error
            ;; and that fixing the guard here is what stops it.
            (set-buffer (orgacle--session-org-buffer session))
            (org-mode)
            (if (orgacle--session-org-restriction session)
                (apply #'narrow-to-region (orgacle--session-org-restriction session))
              (widen))
            (hack-local-variables))
          ;; delete all orgacle overlays
          (orgacle-clean-overlays)
          (orgacle-clean-fringe-overlays)
          (orgacle-reveal-clean-overlays)
          ;; explicit belt-and-braces, not a fix for an observed leak:
          ;; confirmed directly (`(orgacle-mode) ... (org-mode)' on a
          ;; scratch buffer) that switching a buffer's major mode back
          ;; to plain `org-mode', as the block just above already does,
          ;; already resets `face-remapping-alist' to nil via the
          ;; ordinary `kill-all-local-variables' every major-mode
          ;; function runs -- unlike an overlay, which is a buffer
          ;; object with nothing to do with buffer-local variables and
          ;; so is untouched by any mode switch, which is why
          ;; `orgacle-reveal-clean-overlays' just above genuinely is
          ;; load-bearing here.  This call is kept anyway, matching the
          ;; rest of this function's practice of restoring state
          ;; explicitly rather than depending on an incidental side
          ;; effect of code that could change shape later (for example
          ;; if the `org-mode' call above ever became conditional): it
          ;; is a safe no-op given the mode switch already ran, and it
          ;; is also what reaches a narrowed presentation's remapping,
          ;; on the temporary export buffer already killed a few lines
          ;; up, before this call ever runs -- also a no-op there, via
          ;; the `buffer-live-p' guard in `orgacle-appearance-clean-text-scale'
          ;; itself, since killing a buffer discards its buffer-local
          ;; state regardless.  The session's frame is deleted earlier
          ;; in this same `unwind-protect', so there is nothing to
          ;; restore ORGACLE_BACKGROUND against either
          (orgacle-appearance-clean-text-scale)
          ;; kill notes buffer and associated frame, if present.
          ;; ALL-FRAMES is t here (I4, code review, fix round 1) --
          ;; `get-buffer-window' with no ALL-FRAMES argument only looks
          ;; at windows on the *selected* frame, and the realistic
          ;; caller of this function via item 4's recovery route is
          ;; exactly the case where that assumption fails: the window
          ;; manager has already killed the presentation frame, so
          ;; whichever frame Emacs falls back to as "selected" by the
          ;; time this runs need not be the notes frame at all.  With
          ;; no ALL-FRAMES, `win' stayed nil on that path, `delete-frame'
          ;; was never called, and the notes buffer was killed out from
          ;; under a frame that survived orphaned -- confirmed live,
          ;; with two real frames: the window manager kills the
          ;; presentation frame, `M-x orgacle-run' from the deck buffer
          ;; leaves four frames total afterward, the stale notes frame
          ;; among them, now showing the deck file itself.
          ;;
          ;; The ordinary `q' path never surfaced this -- not, as an
          ;; earlier version of this comment claimed, because the
          ;; selected frame there is "still whatever frame `q' was
          ;; pressed in": `q' is pressed *in* the presentation frame,
          ;; and this same function deletes that exact frame some
          ;; twenty lines above this point, so by the time execution
          ;; reaches here the presentation frame is already gone and
          ;; Emacs has already re-selected some other one.  Corrected,
          ;; code review (fix round 2, Important 3), instrumented on a
          ;; real live `q': the frame selected by this point is the
          ;; *notes* frame, simply because it is the only other frame
          ;; left once the presentation frame above is deleted, in the
          ;; ordinary one-presentation-plus-one-notes-frame case -- and
          ;; the notes frame is exactly the one this call needs to
          ;; find, so the ordinary path worked by this coincidence of
          ;; frame re-selection, not for the reason originally given.
          ;; Item 4's recovery route breaks that coincidence, not the
          ;; underlying assumption it was never safe to make: it can
          ;; leave a *third* frame selected by this point -- neither
          ;; the presentation frame just deleted nor the notes frame --
          ;; which is what actually made ALL-FRAMES the fix rather than
          ;; any particular frame-selection order.
          (when (and session (bufferp (orgacle--session-notes-buffer session)))
            (let ((win (get-buffer-window (orgacle--session-notes-buffer session) t)))
              (when win (delete-frame (window-frame win))))
            (kill-buffer (orgacle--session-notes-buffer session))))
      ;; restore the user's Org-mode variables, tooltip setting,
      ;; display-table slot and X pointer state, even if something above
      ;; failed; see `orgacle--restore-user-state', which only touches the
      ;; pointer when `orgacle--save-user-state' actually captured it
      (orgacle--restore-user-state)
      (setq orgacle--session nil))))

(defvar orgacle-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    ;; line movement
    (define-key map "j" 'scroll-up)
    (define-key map [down] 'scroll-up)
    (define-key map "k" 'scroll-down)
    (define-key map [up] 'scroll-down)
    ;; page movement
    (define-key map " " 'orgacle-next-page)
    (define-key map "n" 'orgacle-next-page)
    (define-key map "f" 'orgacle-next-page)
    (define-key map [right] 'orgacle-next-page)
    (define-key map [next] 'orgacle-next-page)
    (define-key map "p" 'orgacle-previous-page)
    (define-key map "b" 'orgacle-previous-page)
    (define-key map [left] 'orgacle-previous-page)
    (define-key map [prior] 'orgacle-previous-page)
    (define-key map [backspace] 'orgacle-previous-page)
    (define-key map "v" 'orgacle-jump-to-page)
    ;; within page functions
    (define-key map "c" 'orgacle-next-src-block)
    (define-key map "C" 'orgacle-previous-src-block)
    (define-key map "e" 'org-edit-src-code)
    (define-key map "E" 'orgacle-edit-text)   ; C-c C-c exits edit mode
    (define-key map "x" 'org-babel-execute-src-block)
    (define-key map "r" 'orgacle-refresh)
    (define-key map "R" 'redraw-display)
    (define-key map "g" 'orgacle-refresh)
    ;; incremental reveal -- orgacle-reveal.el's own keys, working the
    ;; same way regardless of `orgacle-reveal-on-navigation', which
    ;; only governs n/p above; formerly the accordion-style subheading
    ;; commands `orgacle-next-subheading' and `orgacle-previous-subheading'
    ;; (still defined, just unbound by default -- see the README's
    ;; "Revealing a slide piece by piece" section)
    (define-key map "N" 'orgacle-reveal-next)
    (define-key map "P" 'orgacle-reveal-previous)
    ;; show/hide images and videos
    (define-key map "i" 'orgacle-show-file-or-advance)
    (define-key map "I" 'orgacle-show-video)
    ;; show/hide mouse pointer
    (define-key map "m" 'orgacle-toggle-mouse)
    ;; adjust font size
    (define-key map "+" 'orgacle-increase-font)
    (define-key map "-" 'orgacle-decrease-font)
    ;; global controls
    (define-key map "q" 'orgacle-quit)
    (define-key map "1" 'orgacle-top)
    (define-key map "s" 'orgacle-toggle-hide-src-blocks)
    (define-key map "S" 'orgacle-toggle-hide-src-block)
    (define-key map "t" 'orgacle-top)
    map)
  "Local keymap for Orgacle display mode.")

(define-derived-mode orgacle-mode org-mode "Orgacle"
  "Major mode for presenting an Org-mode buffer as a slide show.

Each frame-level heading becomes a slide.  Navigate with
\\<orgacle-mode-map>\\[orgacle-next-page] and \\[orgacle-previous-page], and leave with \\[orgacle-quit].

\\{orgacle-mode-map}"
  ;; make Org-mode be as pretty as possible
  (add-hook 'org-src-mode-hook 'orgacle-setup-src-edit)
  ;; `orgacle--save-user-state' captures the tracked variables, the
  ;; outline-ellipsis display-table slot and the tooltip-mode setting,
  ;; and is a no-op when a save is already pending -- see its docstring
  ;; -- which is what makes re-entering this mode without an
  ;; intervening `orgacle-quit' safe.  It also vivifies
  ;; `standard-display-table' when necessary, so by the time control
  ;; reaches the `set-display-table-slot' call below, the table is
  ;; guaranteed to be a real char-table; this mirrors the `char-table-p'
  ;; guard `orgacle--restore-user-state' uses on the way back.
  (orgacle--save-user-state)
  (setq org-src-fontify-natively t)
  (setq org-fontify-quote-and-verse-blocks t)
  (setq org-hide-emphasis-markers t)
  (set-display-table-slot standard-display-table 'selective-display [32])
  (setq org-pretty-entities t)
  (setq mode-line-format (orgacle-get-mode-line))
  ;; buffer-local (the final, non-nil LOCAL argument): `org-babel-after-execute-hook'
  ;; is a global hook, and adding to it globally meant running a source
  ;; block in any Org buffer whatsoever -- not just the one being
  ;; presented -- rebuilt this session's slide vector out of that
  ;; unrelated buffer, leaving markers pointing into the wrong buffer.
  ;; A buffer-local addition also cannot outlive the buffer it was made
  ;; in, so an abandoned presentation -- its frame killed without
  ;; `orgacle-quit' -- does not leave `orgacle-refresh' wired into every
  ;; future source-block execution for the rest of the Emacs session.
  (add-hook 'org-babel-after-execute-hook 'orgacle-refresh nil t)
  (condition-case ex
      (let ((org-format-latex-options
             (plist-put (copy-tree org-format-latex-options)
                        :scale orgacle-format-latex-scale)))
        (org-latex-preview '(16)))
    (error
     (message "Unable to imagify latex [%s]" (error-message-string ex))))
  ;; `set-face-attribute' treats a nil FRAME argument as *all* frames,
  ;; current and future, not "the selected frame" -- confirmed directly,
  ;; before this fix: entering this mode standalone, with no `orgacle-run'
  ;; -- which the existing test suite already does throughout, see
  ;; `orgacle-test-mode-enters' and the re-entrancy tests just below it
  ;; -- leaves the session's frame slot nil, since only `orgacle--get-frame'
  ;; (called by `orgacle-run', not by this mode function itself) ever
  ;; sets it, so the call below used to permanently resize the `default'
  ;; face on every frame Emacs has, including ones this presentation
  ;; never touched, with nothing anywhere restoring it afterward.
  ;; `orgacle-quit''s own discipline is to restore only what it recorded
  ;; saving; there was never a saved "previous height" here to restore
  ;; it to, so the fix is to stop the damage at its source instead.
  ;;
  ;; Fix round 1 (code review): a first version of this fix fell back to
  ;; `(selected-frame)' whenever the session's own frame was not
  ;; `frame-live-p', reasoning that batch has no real frame of its own
  ;; to work with otherwise.  That still damages a real frame -- the
  ;; *user's own*, whichever one they happened to be looking at when
  ;; they ran `M-x orgacle-mode' with no presentation behind it --
  ;; confirmed live, on two real X frames: entering this mode in a
  ;; plain Org buffer on frame 1, with frame 2 merely present, changed
  ;; frame 1's own height and left it changed, `orgacle-quit' afterward
  ;; included, which never restores a height nothing ever saved, while
  ;; frame 2 and the global default stayed untouched throughout --
  ;; corrected here, code review (fix round 2, Important 3), from this
  ;; comment's own earlier, false "101 to 400, quit leaves it at 398"
  ;; account, which implied `orgacle-quit' itself changed something:
  ;; measured directly, `face-attribute' already reported 398, not 400,
  ;; immediately after `orgacle-mode' returned, before `orgacle-quit'
  ;; ran at all, and still 398 afterward -- it was never 400, and quit
  ;; changed nothing.  There is no frame this call may fall back to
  ;; that is guaranteed not to be a real one the user cares about, so
  ;; it does not fall back at all: only the session's own frame, and
  ;; only when that frame is genuinely `frame-live-p', which is always
  ;; true on the real `orgacle-run' path -- `orgacle--get-frame' is the
  ;; only setter of this slot, and always leaves it live and selected
  ;; before `orgacle-run' calls this mode function.  Corrected here,
  ;; same review round: this was previously claimed to be "never" true
  ;; when this mode is entered standalone instead; false when a
  ;; presentation is already running somewhere else -- `orgacle--session'
  ;; is one global session, not scoped to any one buffer, so
  ;; `orgacle--session-ensure' returns that same live session, frame
  ;; and all, even called from a wholly unrelated buffer, and this
  ;; branch then applies to the *existing* presentation's own frame,
  ;; not to whatever buffer this mode was just entered in -- confirmed
  ;; directly.  Harmless -- it is still a real, `frame-live-p' frame
  ;; Orgacle itself owns and is actively presenting on, not some
  ;; unrelated frame of the user's -- but "never" overstated it; the
  ;; only case genuinely guaranteed to be `frame-live-p' nil here is no
  ;; presentation running anywhere at all, which is the ordinary
  ;; standalone case this whole fix is about, not the only one.
  (let ((frame (orgacle--session-frame (orgacle--session-ensure))))
    (when (frame-live-p frame)
      (set-face-attribute 'default frame :height orgacle-text-scale)))
  ;; fontify the buffer
  (add-to-invisibility-spec '(orgacle-hide))
  ;; remove flyspell overlays
  (when (fboundp 'flyspell-mode-off)
    (flyspell-mode-off))
  (orgacle-fontify)
  ;; hide headings with ORGACLE_HIDE tag or marked as "speaker notes"
  (org-map-entries (lambda ()
		     (when (or
			    (org-entry-get nil "ORGACLE_HIDE")
			    (string= (downcase (org-entry-get nil "ITEM")) "speaker notes")
			    (string= (downcase (org-entry-get nil "ITEM")) "title page"))
		       (org-mark-subtree)
		       ;; we make things insvisile only until mark-1
		       ;; to leave a newline visible, as a separator
		       ;; betwen this heading and the next
		       (push (make-overlay (point) (- (mark) 1)) orgacle-overlays)
		       (overlay-put (car orgacle-overlays)
				    'invisible
				    'orgacle-hide)
		       (deactivate-mark))))
  ;; reset the auxiliary window object
  (setf (orgacle--session-aux-window (orgacle--session-ensure)) nil))

(defvar orgacle-edit-map (let ((map (copy-keymap org-mode-map)))
                            (define-key map (kbd "C-c C-c") 'orgacle-refresh)
                            map)
  "Local keymap for editing an Orgacle presentation.")

(defun orgacle-edit-text ()
  "Edit the presentation text in place.
Press \\<orgacle-edit-map>\\[orgacle-refresh] to stop editing and refresh
the display."
  (interactive)
  (let ((prior-cursor-type (cdr (assoc 'cursor-type (frame-parameters)))))
    (set-frame-parameter nil 'cursor-type t)
    (use-local-map orgacle-edit-map)
    (set-transient-map
     orgacle-edit-map
     (lambda () (not (equal (kbd "C-c C-c") (this-command-keys))))
     (lambda ()
       (use-local-map orgacle-mode-map)
       (set-frame-parameter nil 'cursor-type prior-cursor-type)))))

(defun orgacle--quit-previous-session-if-any (ask)
  "Tear down a previous, real presentation session before a new one begins.
P4 Task 6 Step 3, extracted into its own function in fix round 1 so
the confirm/decline logic below stays testable in batch on its own
terms, and kept in fix round 2 even though `orgacle-run''s own ASK is
now a plain argument rather than something only `called-interactively-p'
could produce: a small, focused unit of the decision logic on its own,
independent of `orgacle-run''s dispatch, is still worth having; see
`orgacle-test-quit-previous-session-confirms-tears-down' and its
sibling in test/orgacle-test.el.

A no-op when there is no previous session, or one exists but never
actually reached a real presentation -- gated on the start-time slot,
set only by a real `orgacle-run' and never by `orgacle--session-ensure'
auto-vivifying a session for some other caller, such as a navigation
command run directly or the test suite's own fixtures: a session that
never actually presented anything has no frame, buffer mode, notes
buffer or temp file to strand, so there is nothing here for it to tear
down, and it must not be mistaken for a live presentation and trigger
a confirmation prompt of its own.

Otherwise: A second `orgacle-run', from a different Org buffer, used
to replace `orgacle--session' with a fresh struct before anything tore
the old one down, so every slot of the old session became unreachable
at once -- not only the reveal overlays and text-scale remapping the
two calls after this function's own call site patch (see their own
comment there).  Measured directly during Task 6, run A then run B
then a single `orgacle-quit': the first notes buffer stranded,
`*Orgacle Notes*', while the new session held `*Orgacle Notes*<2>';
buffer A left in `orgacle-mode' permanently, its restriction never
reapplied; a second frame built while frame A became unreachable; a
narrowed-subtree presentation's temp file never deleted, its buffer
never killed.  See the task report for the reproduction against the
unfixed code, and the tests in test/orgacle-test.el -- search for
\"Step 3\" -- for each of the four pinned individually.

Two options were on the table: refuse outright when a session is
live, or quit the old one first with no confirmation.  Neither alone
is right.  Refusing is safe but leaves a \"quit, then run again\"
dance every time a presenter means to switch decks, for a command
whose whole point is to be fast to invoke.  Quitting
unconditionally can pull the screen out from under an audience still
looking at it, with no way back -- silently ending a presentation is
a strictly worse failure mode than merely refusing to start a new
one.  What this does instead: when ASK is non-nil and the previous
session's frame is still genuinely live -- someone could be looking
at it right now -- ask via `yes-or-no-p' before ending it, the same
idiom `orgacle-migrate-file' already uses for its own \"this would
also discard something\" confirmation.  Declining signals `user-error'
and leaves the old presentation completely untouched, exactly as
refusing outright would have.  When ASK is nil -- see `orgacle-run'
for when that is -- or the frame is already gone -- the window
manager killed it, or this session never actually got as far as
putting anything on screen -- there is nothing live left to lose \(or
no one to ask\), so this cleans up without asking.

Switches to whichever buffer the old session was actually presenting
before quitting it, then switches back: a narrowed-subtree
presentation's real, on-screen buffer is the temporary export buffer
named by the org-file slot, not the org-buffer slot directly -- see
that slot's own docstring on the session struct in orgacle-core.el.
`orgacle-quit' itself acts on several things -- clearing LaTeX
previews, removing the buffer-local `org-babel-after-execute-hook'
addition -- via whatever buffer happens to be current when it is
called, rather than through a session slot, on the assumption that it
is always invoked from inside the presentation it is ending; switching
first makes that assumption true here too, exactly as if the
presenter had gone back there and pressed q themselves.  Switching
back afterwards matters just as much: without it, the `(current-buffer)'
capture inside `orgacle-run', for the *new* session's own org-buffer
slot, would record the old presentation's buffer -- wherever
`orgacle-quit' left it -- instead of the buffer `orgacle-run' was
actually just called from.

The switch-back is guarded on `buffer-live-p', not merely REQUESTED
being non-nil -- Finding 4, fix round 2, I2's un-generalized sibling:
`orgacle-run' can itself be called *from* the old session's own notes
buffer -- plain `org-mode', on screen, in its own frame, exactly what
`orgacle-speaker-notes' \(the default\) documents as the presenter
console, so a presenter genuinely can find themselves there and decide
to start a new presentation from it.  When that happens, REQUESTED is
the notes buffer itself, and `orgacle-quit', called in between, kills
that exact buffer as part of its own \(already correct\) notes-buffer
teardown -- so the switch-back used to hit a dead buffer object and
signal `error', confirmed directly, *after* the old presentation was
already torn down.  Skipping the switch-back when REQUESTED is no
longer live leaves nothing to restore to, which is fine: `orgacle-run'
is about to `find-file'/narrow/`switch-to-buffer' its own way to a
real buffer immediately afterward regardless of what is current here."
  (when (and orgacle--session (orgacle--session-start-time orgacle--session))
    (if (and ask
             (frame-live-p (orgacle--session-frame orgacle--session))
             (not (yes-or-no-p
                   "A presentation is already running.  Quit it and start this one? ")))
        (user-error "Orgacle already running")
      (let* ((requested (current-buffer))
             (old orgacle--session)
             (presented (or (and (orgacle--session-org-file old)
                                  (get-file-buffer (orgacle--session-org-file old)))
                            (orgacle--session-org-buffer old))))
        (when (buffer-live-p presented) (set-buffer presented))
        (orgacle-quit)
        (when (buffer-live-p requested) (set-buffer requested))))))

;;;###autoload
(defun orgacle-run (&optional ask)
  "Present an Org-mode buffer.
With ASK non-nil, and a previous presentation's frame still genuinely
live, confirm before ending it; called interactively -- a real key
press or `M-x' -- ASK is always t, via this command's own `interactive'
spec.  A plain Lisp call, `(orgacle-run)', from a script, an
`after-init-hook', or another command's own body, defaults ASK to nil:
no prompt, ever, regardless of what is still running.  A wrapper
command that means to relay a real, live end-user action -- a small
command that opens one particular deck and presents it, bound to a
key, exactly how a presenter might set one up -- should call
`(orgacle-run t)', or `(call-interactively #\\='orgacle-run)',
explicitly, the same way any Emacs command that wants to relay \"this
is happening for a real, present user\" to something it calls has to
say so explicitly; nothing here can infer that safely on a caller's
behalf.  See `orgacle--quit-previous-session-if-any' for what ASK
actually gates.

Also works from inside the very buffer already being presented: with
the current buffer already in `orgacle-mode' -- for example because
the presentation frame was closed by the window manager instead of
`q', leaving a stale session with nothing to tear it down -- this
treats it exactly like switching decks from a different buffer, via
`orgacle--quit-previous-session-if-any', and then starts fresh, rather
than silently doing nothing."
  (interactive (list t))
  (unless (or (eq major-mode 'orgacle-mode) (eq major-mode 'org-mode))
    (error "Orgacle can only be used from Org Mode"))
  ;; Being already in `orgacle-mode' used to skip this entire function
  ;; body outright -- `(unless (eq major-mode 'orgacle-mode) BODY)' --
  ;; which made a second `orgacle-run' from the deck buffer itself a
  ;; silent no-op, interactively and as a plain Lisp call alike.  The
  ;; realistic way a presenter reaches that: the window manager closes
  ;; the presentation frame instead of `q', leaving the deck buffer in
  ;; `orgacle-mode' with a stale session and no live frame to quit.
  ;; `orgacle--quit-previous-session-if-any' below already exists for
  ;; exactly this shape of teardown -- it was built for the "switch
  ;; decks" case, but nothing about it depends on the *new* presentation
  ;; being a different buffer -- so this now runs unconditionally
  ;; instead, whether the current buffer is already `orgacle-mode' or a
  ;; plain `org-mode' buffer, and relies entirely on its own start-time
  ;; and `frame-live-p' gates to stay a no-op when there is truly
  ;; nothing to tear down.  Confirmed directly, before this fix, that
  ;; `orgacle--session' after a second `(orgacle-run t)' called from the
  ;; still-`orgacle-mode' buffer was still `eq' to the first call's own
  ;; session -- proving nothing had happened -- and that with the frame
  ;; slot already dead, `yes-or-no-p' is never reached either, so this
  ;; recovers silently rather than asking a question the presenter has
  ;; no live presentation left to answer about.
  ;;
  ;; The Ruling, P4 Task 6 fix round 2, replacing fix round 1's own
  ;; `called-interactively-p'-based version: that signal turned out
  ;; to be backwards on both cases that actually matter, and
  ;; untestable in the specific way that would have caught it --
  ;; Findings 2 and 3 of that round's review.  `called-interactively-p'
  ;; asks whether *this* function's own immediate caller reached it
  ;; through the command loop, which is the wrong question for a
  ;; wrapper command like the one this docstring's own example
  ;; describes: such a wrapper *is* a real key press from the
  ;; presenter's own perspective, but its own call to `(orgacle-run)'
  ;; is, textually, just an ordinary Lisp form, so
  ;; `(called-interactively-p 'interactive)' evaluated *inside*
  ;; `orgacle-run' returns nil there regardless -- the exact "torn
  ;; down with no confirmation" failure mode this whole feature
  ;; exists to prevent.  A plain ASK argument, with its own
  ;; `interactive' spec supplying it automatically for a direct key
  ;; press or `M-x', is the fix Emacs's own `called-interactively-p'
  ;; docstring already names for exactly this situation.  It is also
  ;; what makes both branches ordinary, direct batch tests:
  ;; `(orgacle-run)' and `(orgacle-run t)' need no live command loop
  ;; to differ, and `(call-interactively 'orgacle-run)' correctly
  ;; evaluates this function's own `interactive' spec even in batch,
  ;; confirmed directly, unlike `called-interactively-p' itself.
  (orgacle--quit-previous-session-if-any ask)
  ;; delete the previous presentation's reveal overlays and
  ;; text-scale remapping before its session is replaced below.
  ;; Independent of the block just above, which only fires for a
  ;; session that actually reached a real presentation: a session
  ;; auto-vivified by some other caller -- again, a navigation
  ;; command run directly, or the test suite -- can still carry
  ;; leftover reveal overlays or a text-scale remapping of its own
  ;; (both are reachable through plain navigation, with no
  ;; `orgacle-run' involved), and the block above deliberately leaves
  ;; such a session alone rather than tearing it down or asking about
  ;; it.  `orgacle-quit' already cleans both for any session the
  ;; block above did handle, so these two calls are a safe no-op
  ;; there -- `orgacle-reveal-clean-overlays' and
  ;; `orgacle-appearance-clean-text-scale' both auto-vivify a fresh,
  ;; empty session via `orgacle--session-ensure' when `orgacle--session'
  ;; is nil, which is exactly what the block above just set it to.
  (orgacle-reveal-clean-overlays)
  (orgacle-appearance-clean-text-scale)
  ;; a fresh session, not a mutated leftover one: a presentation whose
  ;; frame was killed without going through `orgacle-quit' must not be
  ;; able to leave this one inheriting its state
  (setq orgacle--session (orgacle--session-create))
  ;; the talk timer measures from here, not from whenever the mode
  ;; line happens to first redisplay
  (setf (orgacle--session-start-time orgacle--session) (float-time))
  (setf (orgacle--session-org-buffer orgacle--session) (current-buffer))
  ;; regenerate image previews
  (orgacle--link-preview-refresh)
  ;; To present narrowed region use temporary buffer
  (when (and (or (> (point-min) (save-restriction (widen) (point-min)))
                 (< (point-max) (save-restriction (widen) (point-max))))
             (save-excursion (goto-char (point-min)) (org-at-heading-p)))
    (let ((title (nth 4 (org-heading-components))))
      (setf (orgacle--session-org-restriction orgacle--session)
            (list (point-min) (point-max)))
      (require 'ox-org)
      (setf (orgacle--session-org-file orgacle--session)
            (org-org-export-to-org nil 'subtree))
      (find-file (orgacle--session-org-file orgacle--session))
      (goto-char (point-min))
      (insert (format "#+Title: %s\n\n" title))))
  (setq orgacle-frame-level (orgacle-get-frame-level))
  ;; build the slide vector navigation is index arithmetic over
  (orgacle--start-slides)
  ;; save the user's state before `orgacle--get-frame' sets the mouse
  ;; pointer to the presentation's own shape: `orgacle--save-user-state'
  ;; is a no-op once a save is already pending, so `orgacle-mode's own
  ;; call below stays harmless, but the pointer capture inside this one
  ;; has to happen before that mutation, not after it, to see the
  ;; user's real prior setting rather than the presentation's own
  (orgacle--save-user-state)
  (orgacle--get-frame)
  (orgacle-mode)
  (set-buffer-modified-p nil)
  (setf (orgacle--session-presentation-window orgacle--session) (selected-window))
  ;; set/unset tooltips; `orgacle-mode', called above, has already
  ;; saved the user's prior setting via `orgacle--save-user-state'
  (tooltip-mode (if orgacle-tooltip-mode 1 -1))
  ;; create speaker notes
  (when orgacle-speaker-notes (orgacle-make-notes-buffer))
  ;; display the first slide: `orgacle--start-slides' only builds the
  ;; slide vector and resets the index and page number, it does not
  ;; narrow the buffer or run the page hook, so without this call the
  ;; buffer would stay unnarrowed with `orgacle-page-number' at 1 but
  ;; nothing actually on display, and the first `orgacle-next-page'
  ;; would compute (1+ 0) and jump straight to slide 2 -- slide 1
  ;; would then be reachable only via `orgacle-top', `t' or `1'.
  ;; Called after `orgacle-make-notes-buffer' so the page hook's
  ;; `orgacle-position-notes' has a notes buffer to position when it
  ;; fires as part of showing this first slide.
  (orgacle-top)
  (run-hooks 'orgacle-start-presentation-hook))

;;; Migration

;;;###autoload
(defun orgacle-migrate-buffer (&optional beg end)
  "Convert EPRESENT_ names to ORGACLE_ between BEG and END.
Without BEG and END, convert the accessible portion of the buffer, or
the region when one is active -- so a narrowed buffer only has its
visible part converted.  Return the number of substitutions, and
report it in the echo area when called interactively.

Presentations written before the ORGACLE_ rename use the older
names; this brings them up to date."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let ((count 0)
        (case-fold-search nil))
    (save-excursion
      (save-restriction
        (when (and beg end) (narrow-to-region beg end))
        (goto-char (point-min))
        (while (re-search-forward "EPRESENT_" nil t)
          (replace-match "ORGACLE_" t t)
          (setq count (1+ count)))))
    (when (called-interactively-p 'interactive)
      (message "Converted %d name%s" count (if (= count 1) "" "s")))
    count))

;;;###autoload
(defun orgacle-migrate-file (file)
  "Convert EPRESENT_ names to ORGACLE_ in FILE, saving it.
The whole file is converted, regardless of any narrowing in an
already-open buffer visiting it.  When FILE is already open with
unsaved changes, ask first: saving it would write those changes too."
  (interactive "fMigrate file: ")
  (let ((visiting (find-buffer-visiting file)))
    (when (and visiting (buffer-modified-p visiting)
               (not (yes-or-no-p
                     (format "%s has unsaved changes that would also be saved.  Continue? "
                             (file-name-nondirectory file)))))
      (user-error "Migration cancelled")))
  (with-current-buffer (find-file-noselect file)
    (let ((count (save-restriction (widen) (orgacle-migrate-buffer))))
      (save-buffer)
      (message "Converted %d name%s in %s"
               count (if (= count 1) "" "s") (file-name-nondirectory file))
      count)))

;;; Unloading

(defun orgacle-unload-function ()
  "Restore the user's own state, then unload every submodule `orgacle.el' requires.
`unload-feature' -- see its own docstring -- only removes, from a hook
variable, functions *defined by the file actually being unloaded*, and
by default `(unload-feature \\='orgacle)' only ever unloads this file,
orgacle.el, never the submodules it `require's.  That misses real
state Orgacle installs outside orgacle.el's own symbols entirely: all
six `orgacle-page-hook' members -- `orgacle-slide-in-effect'
\(orgacle-fontify.el\), `orgacle-show-file-auto' and
`orgacle-show-indicators-maybe' \(orgacle-media.el\),
`orgacle-position-notes' \(orgacle-notes.el\), `orgacle-reveal-reset'
\(orgacle-reveal.el\) and `orgacle--apply-appearance'
\(orgacle-appearance.el\) -- and the `:after' advice orgacle-src.el
puts on Org's own `org-edit-src-exit' \(see that file's own
`orgacle--refresh-after-src-edit' and `orgacle-src-unload-function'\).
Confirmed directly, before writing this function: `(unload-feature
\\='orgacle t)' alone left all six hook members installed and the
advice in place.

Fix round 1 (code review), replacing this function's first version,
which instead removed the six hook members by exact symbol and called
`orgacle-src-unload-function' directly, leaving the other eight
submodules -- and every ordinary function they define -- loaded and
untouched.  That fixed the two symptoms above, but left a worse one
behind: load, unload, load \(`(require \\='orgacle)', `(unload-feature
\\='orgacle t)', `(require \\='orgacle)' again\) left `orgacle-mode'
`fboundp' again, looking loaded, while `orgacle-page-hook' stayed
empty and the advice stayed gone -- because the eight submodules were
never removed from `features' in the first place, so the second
`require' saw them all already provided and reloaded none of them,
silently skipping every one of their own top-level `add-hook' and
`advice-add' calls.  A live presentation after that reload would
navigate slides while slide-in, automatic image display, fringe
indicators, notes positioning, incremental reveal and per-slide
appearance all stayed dead, with nothing anywhere signalling an error.
`package.el' itself never calls `unload-feature', but a maintainer or
a MELPA reviewer checking this exact function does, and a package that
only pretends to reload is worse than one honest about not
supporting it.

The fix: unload every submodule, not just handle the two symptoms by
hand.  `(unload-feature FEATURE t)' on each triggers that submodule's
own standard unloading in turn, which is what actually removes the six
hook members \(each one is `defined by the file actually being
unloaded' from that submodule's own point of view\) and runs
`orgacle-src-unload-function' for the advice, exactly the way
`unload-feature' is meant to work, with no need to hand-duplicate any
of it here.  It also incidentally reaches a third, narrower leak the
first version of this function did not handle: `orgacle-mode' adds
`orgacle-setup-src-edit' to the *global* `org-src-mode-hook' for the
duration of a presentation, and unloading `orgacle-src' removes that
too, by the same standard mechanism, if a presentation happened to be
live when unload ran -- confirmed directly, seeding that hook by hand
before unloading, though not confirmed to have ever actually broken
anything in a shipped version, since round 0's own version of this
function never unloaded `orgacle-src' at all, leaving
`orgacle-setup-src-edit' `fboundp' throughout and a real
`org-edit-src-code'/`org-edit-src-exit' round trip working regardless.

FORCE is passed on every one of the nine calls, and is needed on every
one of them, but not for the reason an earlier version of this
docstring gave -- \"every later submodule still requires
`orgacle-core'\" -- which covers at most one call and, measured
directly, not even that one cleanly: attempting all nine without FORCE
shows the blocker named in the error is `orgacle.elc' itself, still
counted as a loaded dependent of *every* submodule, for all nine calls
including `orgacle-core' once the other eight have already been
unloaded first.  That is because `orgacle.el' itself is not yet
removed from `features' while this function runs -- `unload-feature
\\='orgacle' only does that as part of its own standard unloading,
*after* this function returns -- so from `unload-feature's own
dependency check's point of view, orgacle.el, the file `require'-ing
all nine of these, is still \"loaded\" throughout, and would refuse
every single one of these calls without FORCE regardless of any
dependency the nine submodules have among themselves.  Order here is
reverse of the `require's above, most specific first and `orgacle-core'
last, on general principle -- unloading a dependency before its own
dependents matches how `unload-feature' itself is written to prefer
being used -- though FORCE makes the actual order immaterial to
whether any individual call here succeeds.

Trade-off, previously undocumented: round 0's version of this function
removed the six hook members by exact symbol, deliberately preserving
any member a third party might have added to this public,
documented-as-extensible variable directly.  Cascading `orgacle-core'
away, and letting it come back through a plain `defvar' on reload,
does not preserve that -- confirmed directly, seeding a third-party
function onto `orgacle-page-hook' before unloading: it does not
survive unload and reload, the ordinary way `unload-feature' handles
any variable a file `defvar's, with no special case for one this
package happens to treat as a public extension point.  Kept anyway:
the alternative -- hand-filtering the six known members back out on
reload, the way round 0 did on the way out -- would have to happen
*after* `require', outside this function's own reach entirely, and
reintroduces exactly round 0's own hand-maintained-list fragility for
a scenario \(a third party's function surviving a `maintainer-only'
`unload-feature' call\) with no report or test demonstrating it matters
in practice, unlike the two symptoms and the two Important findings
this function exists to fix, all of which were.

Important 2 (code review, fix round 2).  `orgacle--saved-state' and
`orgacle-user-tooltip-mode' -- the presenter's own prior values for
`orgacle-saved-variables' and `tooltip-mode', captured by
`orgacle--save-user-state' when a presentation starts -- live in
`orgacle-core', which this cascade unloads and `makunbound's.
Measured directly, before this fix, on a live presentation: unload,
`require' again, then `orgacle-quit' -- all of the tracked variables
and `tooltip-mode' stayed in their *presentation* values, globally,
for the rest of the Emacs session, because `orgacle--restore-user-state'
itself had already gone void and come back on reload defining a fresh,
empty `orgacle--saved-state', with no memory of what the presentation
had been holding; there is no `orgacle-quit' left afterward that could
recover it.  Fixed by calling `orgacle--restore-user-state' here
first, while `orgacle-core' and the state it needs are both still
live, so the restore happens as part of the unload itself; a no-op,
via that function's own guard, when no presentation was live to begin
with.  This does only that one, narrow restore -- not a full
`orgacle-quit', which would also delete the presentation's own frame
and kill its notes buffer, side effects a maintainer calling
`unload-feature' directly has not asked for and this function has no
business taking on their behalf.

Important 1 (code review, fix round 2).  `org-export-define-derived-backend',
in ox-orgacle.el, registers a backend struct in Org's own
`org-export-registered-backends', outside any single file's own
`load-history' the same way the six `orgacle-page-hook' members and
the `org-edit-src-exit' advice were, and so outside `unload-feature''s
standard unloading for the same reason.  Confirmed directly, before
this fix: after this cascade unloaded `ox-orgacle', `(org-export-get-backend
\\='orgacle)' still returned the full struct, still naming
`orgacle-export-to-pdf' and the rest, all four now void.  Fixed by
calling `orgacle--ox-remove-backend' -- see ox-orgacle.el's own
docstring on that function for why it is not simply named
`ox-orgacle-unload-function' and left for `unload-feature' to
auto-discover, the way `orgacle-src-unload-function' already is --
explicitly, before this function's own cascade reaches `ox-orgacle'
below, since `orgacle--ox-remove-backend' itself would otherwise go
void along with everything else ox-orgacle.el defines before ever
running.

Returns nil, so `unload-feature' still performs its own standard
unloading of orgacle.el's own definitions -- `orgacle-mode',
`orgacle-quit', `orgacle-run', `orgacle-mode-map' and the rest -- after
this function returns; a non-nil return here would suppress that
entirely, per `unload-feature''s own docstring, which is not what this
is for."
  (when (fboundp 'orgacle--restore-user-state)
    (orgacle--restore-user-state))
  (when (fboundp 'orgacle--ox-remove-backend)
    (orgacle--ox-remove-backend))
  (dolist (feature '(ox-orgacle orgacle-appearance orgacle-reveal
                      orgacle-notes orgacle-media orgacle-src
                      orgacle-fontify orgacle-nav orgacle-core))
    (when (featurep feature)
      (unload-feature feature t)))
  nil)

(provide 'orgacle)
;;; orgacle.el ends here
