;;; orgacle-notes.el --- Speaker notes for Orgacle  -*- lexical-binding: t; -*-

;; This file is part of Orgacle.  See orgacle.el for the package header,
;; copyright and licence.

;;; Commentary:

;; Speaker notes for Orgacle: collecting each slide's "Speaker notes"
;; subtree into a buffer of its own, keeping that buffer's view in step
;; with the slide being presented, and estimating how long the notes
;; take to read aloud.

;;; Code:

(require 'orgacle-core)

(defun orgacle-position-notes ()
  "Scroll the notes buffer to the notes for the current slide.
Jumps straight to the marker at the session's index slot in its
notes-markers slot -- the notes buffer's counterpart to the slides
slot, built in the same order by `orgacle--build-notes-buffer' --
instead of searching the notes buffer for the current heading's text,
so two slides sharing a title each keep their own notes, and a title
containing regexp syntax cannot send the search astray.  Does nothing,
rather than signalling, when there is no notes buffer, or when the
index slot is at or past the end of the notes-markers slot: the former
covers a deck with no speaker notes at all, and the latter a marker
vector left stale by `orgacle-refresh' rebuilding the slides slot
without rebuilding the notes buffer."
  (interactive)
  (let* ((session (orgacle--session-ensure))
         (index (orgacle--session-index session))
         (notes-buffer (orgacle--session-notes-buffer session))
         (notes-markers (orgacle--session-notes-markers session)))
    (when (and notes-buffer
               (< index (length notes-markers)))
      (let ((marker (aref notes-markers index)))
        (with-selected-window (get-buffer-window notes-buffer t)
          (widen)
          (goto-char marker)
          (org-narrow-to-subtree)
          (recenter 0))))))

(defun orgacle--presenter-header ()
  "Return the presenter console's header line for the current slide.
Shows the slide's position as N/M, the following slide's title when
there is one, and the talk timer from `orgacle--timer-string' when it
has something to show -- each present segment separated from its
neighbours by two spaces, and simply omitted, with no separator left
dangling in its place, when it has nothing to contribute: the
following-slide segment on the last slide, and the timer whenever no
target duration is configured.  Reads the running session's slides and
index slots directly, the same state `orgacle-position-notes' and
`orgacle--sync-page-number' already read, rather than keeping any
state of its own, so the header always reflects wherever navigation
last left the presentation, with nothing of its own to fall out of
step.

Runs with the presented Org buffer selected -- the buffer the
session's slides slot markers actually point into, which is the
buffer `orgacle-run' was called from, except when a narrowed subtree
is being presented from a temporary exported file, where it is that
file's buffer instead -- rather than whatever buffer happens to be
current when this is called.  In practice that is the notes buffer
itself: `orgacle--build-notes-buffer' installs this function as that
buffer's `header-line-format', and a header-line \\='(:eval FORM)\\='
runs FORM with the buffer displaying it current, not the presented Org
buffer.  Without switching buffers here, `orgacle--timer-string' would
have `orgacle--duration' search the notes buffer for
\"#+ORGACLE_DURATION:\", which it never carries, silently losing a
per-file target that the main presentation frame's own mode line
honours correctly.

Returns \"0/0\", with no following-slide segment and no timer, when the
session's slides slot is empty -- a deck with no real slides at all,
including before `orgacle--start-slides' has ever run -- since there is
then no slide whose buffer to switch to.

Returns the bare N/M position, again with no following-slide segment
and no timer, when the current slide's marker buffer is no longer
live: `marker-buffer' returns nil once a buffer is killed, which is
reachable here even though the notes frame usually goes away together
with the presented buffer, because nothing forces the two to close in
lockstep -- most directly, killing the temporary exported file
`orgacle-run' visits for a narrowed-subtree presentation while the
notes frame is still up.  Since this function runs on every redisplay
of the notes buffer rather than in response to a keypress, the usual
`condition-case' a keystroke command could wrap around a stale-marker
error is not available here: a live buffer to fail against is checked
first instead, and only the always-computable position is shown, to
avoid the alternative of an error spamming *Messages* on every
redisplay for as long as the notes frame stays open."
  (let* ((session (orgacle--session-ensure))
         (slides (orgacle--session-slides session))
         (total (length slides))
         (index (orgacle--session-index session)))
    (if (zerop total)
        "0/0"
      (let* ((position (format "%d/%d" (1+ index) total))
             (buffer (marker-buffer (aref slides index))))
        (if (not (buffer-live-p buffer))
            position
          (with-current-buffer buffer
            (let* ((next-index (1+ index))
                   (next (and (< next-index total)
                              (save-excursion
                                (save-restriction
                                  (widen)
                                  (goto-char (aref slides next-index))
                                  (org-entry-get nil "ITEM")))))
                   (timer (orgacle--timer-string)))
              (mapconcat #'identity
                         (delq nil
                               (list position
                                     (and next (concat "Next: " next))
                                     (and (not (string= timer "")) timer)))
                         "  "))))))))

(defun orgacle--collect-notes-segments ()
  "Return this buffer's speaker notes as a list of per-slide strings.
One element per slide in the session's slides slot, in order --
already built by `orgacle--start-slides' by the time
`orgacle--build-notes-buffer' calls this.  Each element is that
slide's first-level heading line,
followed by the body of its \"Speaker notes\" subtree when it has one.
Iterating the fixed-length slide vector, rather than the whole buffer
heading by heading, is also what keeps the last slide from being
emitted twice: there is no off-by-one loop condition left to get
wrong.  Returning one string per slide, rather than one string for the
whole deck, is what lets `orgacle--build-notes-buffer' record each
slide's marker at the moment its segment is inserted, instead of
inferring slide boundaries from the assembled text afterwards.

A candidate heading is confirmed with the same
\\='(downcase (org-entry-get nil \"ITEM\"))\\=' test that
`orgacle--slide-p', `orgacle-mode's hiding loop and
`orgacle--speaker-word-count' all use, rather than a regexp matched
against the raw heading line.  `org-entry-get's ITEM value has already
had any TODO keyword, priority cookie and tags stripped, so a heading
such as \"** TODO Speaker notes\" or \"** Speaker notes :notes:\" still
matches here exactly like a plain \"** Speaker notes\" does; a raw-line
regexp match would silently miss both, dropping their contents from the
notes buffer entirely."
  (let (segments (slides (orgacle--session-slides (orgacle--session-ensure))))
    (save-excursion
      (save-restriction
        (widen)
        (dotimes (i (length slides))
          (goto-char (aref slides i))
          (let* ((heading (org-entry-get nil "ITEM"))
                 (subtree-end (save-excursion (org-end-of-subtree t t) (point)))
                 (segment (concat "* " heading "\n"))
                 (notes-pos nil))
            (let ((case-fold-search nil))
              (save-excursion
                (while (and (not notes-pos)
                            (re-search-forward "^\\*+[ \t]+" subtree-end t))
                  (when (string= (downcase (or (org-entry-get nil "ITEM") ""))
                                 "speaker notes")
                    (setq notes-pos (point)))
                  (end-of-line))))
            (when notes-pos
              (goto-char notes-pos)
              (org-back-to-heading t)
              (org-mark-subtree)
              (setq segment
                    (concat segment
                            (buffer-substring (point) (mark))
                            "\n"))
              (deactivate-mark))
            (push segment segments)))))
    (nreverse segments)))

(defun orgacle--collect-notes ()
  "Return this buffer's speaker notes as Org text.
The concatenation of `orgacle--collect-notes-segments', which see for
how each slide contributes its heading and \"Speaker notes\" body."
  (apply #'concat (orgacle--collect-notes-segments)))

(defun orgacle--build-notes-buffer ()
  "Build the session's notes-buffer and notes-markers slots; return the buffer.
Inserts each of `orgacle--collect-notes-segments' into a fresh buffer
one at a time, recording that segment's marker in the notes-markers
slot at the moment it is inserted -- so the marker sequence is never
separately inferred by re-scanning the assembled text for lines that
look like headings, which a stray line starting with a literal star
and a space inside a speaker note's own body could otherwise miscount
as an extra slide and misalign every marker after it.  Strips the
\"Speaker notes\" heading lines themselves afterwards, keeping their
bodies.  Reuses the window already showing the previous notes buffer,
if any, so a live presentation's notes frame follows an
`orgacle-refresh' rebuild instead of going blank.  Kills the previous
notes buffer first.  Does not create a frame; see
`orgacle-make-notes-buffer' for that.

Narrows to the marker for the session's current index slot rather than
unconditionally to `point-min' -- always the first slide's segment --
so a rebuild triggered without an intervening navigation, such as
`orgacle-refresh' (bound to r and g, run on exiting `orgacle-edit-text',
and added to `org-babel-after-execute-hook', so it also fires on every
`x' that runs a source block) leaves the notes screen on the slide the
presenter is actually looking at instead of rewinding it to slide 1.
This is a no-op for the initial build, where the index slot is 0: the
first segment always starts at `point-min' anyway.  Falls back to
`point-min' when the index slot is nil or past the end of the
notes-markers slot, the same cases `orgacle-position-notes' guards
against -- a fresh session before `orgacle--start-slides' has run, or a
deck with no speaker notes segments at all.

Sets the buffer's `header-line-format' to evaluate
`orgacle--presenter-header' when `orgacle-presenter-view' is non-nil,
and to nil -- no header line at all -- when it is nil, so the buffer
this function builds with the option off is the exact buffer it always
built: the header lives in `header-line-format', never in the inserted
text itself, so there is nothing in the buffer's contents for the
option to change either way.  A header line evaluated this way needs
no page-hook member of its own to track navigation, the same way
`orgacle-mode-line's default already tracks the page number and timer
in the presentation frame without one: Emacs re-evaluates a
`(:eval FORM)' construct on every redisplay."
  (let* ((session (orgacle--session-ensure))
         (segments (orgacle--collect-notes-segments))
         (win (and (bufferp (orgacle--session-notes-buffer session))
                   (get-buffer-window (orgacle--session-notes-buffer session) t))))
    (if (bufferp (orgacle--session-notes-buffer session))
        (kill-buffer (orgacle--session-notes-buffer session)))
    (setf (orgacle--session-notes-buffer session)
          (generate-new-buffer "*Orgacle Notes*"))
    (with-current-buffer (orgacle--session-notes-buffer session)
      (erase-buffer)
      (org-mode)
      (setf (orgacle--session-notes-markers session)
            (vconcat
             (mapcar (lambda (segment)
                       (let ((start (point)))
                         (insert segment)
                         (copy-marker start t)))
                     segments)))
      (goto-char (point-min))
      (while (re-search-forward "\\*\\* ?.* Speaker [nN]otes[ \t]*\n" nil t)
        (replace-match ""))
      (let ((index (orgacle--session-index session))
            (markers (orgacle--session-notes-markers session)))
        (goto-char (if (and index (< index (length markers)))
                       (aref markers index)
                     (point-min))))
      (org-narrow-to-subtree)
      (setq header-line-format
            (and orgacle-presenter-view '(:eval (orgacle--presenter-header)))))
    (when win (set-window-buffer win (orgacle--session-notes-buffer session)))
    (orgacle--session-notes-buffer session)))

(defun orgacle-make-notes-buffer ()
  "Collect speaker notes into a buffer and show it in a new frame.
With `orgacle-presenter-view' non-nil (the default), that buffer is a
presenter console: `orgacle--build-notes-buffer' gives it a header
line naming the current slide's position, the following slide's
title, and the talk timer, above the current slide's own notes."
  (interactive)
  (orgacle--build-notes-buffer)
  (switch-to-buffer-other-frame
   (orgacle--session-notes-buffer (orgacle--session-ensure))))

(defun orgacle--speaker-word-count ()
  "Return the number of words in this buffer's speaker-notes subtrees."
  (let ((speaker-words 0))
    (org-map-entries
     (lambda ()
       (when (string= (downcase (org-entry-get nil "ITEM")) "speaker notes")
         (save-excursion
           (org-mark-subtree)
           (setq speaker-words (+ speaker-words (count-words (point) (mark))))
           (deactivate-mark)))))
    speaker-words))

(defun orgacle--speaking-time (words)
  "Return the estimated time in minutes to speak WORDS aloud.
The result is rounded up to the next half minute.  The reading speed is
`orgacle-wpm'."
  (/ (ceiling (* (/ (float words) orgacle-wpm) 2)) 2.0))

(defun orgacle-estimate-time ()
  "Report how long it would take to read all speaker notes aloud.
The estimate and the word count are shown in the echo area.  The
reading speed is `orgacle-wpm'."
  (interactive)
  (let* ((words (orgacle--speaker-word-count))
         (minutes (orgacle--speaking-time words)))
    (message "Estimated speaking time in minutes: %s (%d words)"
             minutes words)))

;; Joins `orgacle-page-hook' at load time, last, reproducing the order
;; `orgacle-current-page' used to call these functions in.  This file
;; is required last among the page-hook contributors, so APPEND is
;; passed non-nil to append rather than prepend: prepending here would
;; put the notes ahead of the file, slide-in and indicator handlers
;; already registered, instead of after them.  See orgacle-media.el
;; for the rest of the ordering.
(add-hook 'orgacle-page-hook #'orgacle-position-notes t)

(provide 'orgacle-notes)
;;; orgacle-notes.el ends here
