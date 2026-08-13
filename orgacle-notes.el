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
Jumps straight to the marker at `orgacle--slide-index' in
`orgacle--notes-markers' -- the notes buffer's counterpart to
`orgacle--slides', built in the same order by
`orgacle--build-notes-buffer' -- instead of searching the notes buffer
for the current heading's text, so two slides sharing a title each
keep their own notes, and a title containing regexp syntax cannot
send the search astray.  Does nothing, rather than signalling, when
there is no notes buffer, or when `orgacle--slide-index' is at or past
the end of `orgacle--notes-markers': the former covers a deck with no
speaker notes at all, and the latter a marker vector left stale by
`orgacle-refresh' rebuilding `orgacle--slides' without rebuilding the
notes buffer."
  (interactive)
  (when (and orgacle-notes-buffer
             (< orgacle--slide-index (length orgacle--notes-markers)))
    (let ((marker (aref orgacle--notes-markers orgacle--slide-index)))
      (with-selected-window (get-buffer-window orgacle-notes-buffer t)
        (widen)
        (goto-char marker)
        (org-narrow-to-subtree)
        (recenter 0)))))

(defun orgacle--collect-notes ()
  "Return this buffer's speaker notes as Org text.
Walks `orgacle--slides' in order -- already built by
`orgacle--start-slides' by the time `orgacle--build-notes-buffer' calls
this -- so each slide contributes exactly one first-level heading,
followed by the body of its \"Speaker notes\" subtree when it has one.
Iterating the fixed-length slide vector, rather than the whole buffer
heading by heading, is also what keeps the last slide from being
emitted twice: there is no off-by-one loop condition left to get
wrong."
  (let ((speaker-notes ""))
    (save-excursion
      (save-restriction
        (widen)
        (dotimes (i (length orgacle--slides))
          (goto-char (aref orgacle--slides i))
          (let ((heading (org-entry-get nil "ITEM"))
                (subtree-end (save-excursion (org-end-of-subtree t t) (point))))
            (setq speaker-notes (concat speaker-notes "* " heading "\n"))
            (let ((case-fold-search nil))
              (when (re-search-forward
                     "^\\*+[ \t]+Speaker notes[ \t]*$" subtree-end t)
                (org-back-to-heading t)
                (org-mark-subtree)
                (setq speaker-notes
                      (concat speaker-notes
                              (buffer-substring (point) (mark))
                              "\n"))
                (deactivate-mark)))))))
    speaker-notes))

(defun orgacle--build-notes-buffer ()
  "Build `orgacle-notes-buffer' and `orgacle--notes-markers'; return the buffer.
Collects the current buffer's speaker notes with `orgacle--collect-notes'
into a fresh buffer, strips the \"Speaker notes\" heading lines
themselves (keeping their bodies), and records one marker per
first-level heading in `orgacle--notes-markers', in order -- which is
one per slide, in slide order, since `orgacle--collect-notes' walks
`orgacle--slides'.  Kills any previous `orgacle-notes-buffer' first.
Does not display the buffer; see `orgacle-make-notes-buffer' for that."
  (let ((notes (orgacle--collect-notes)))
    (if (bufferp orgacle-notes-buffer)
        (kill-buffer orgacle-notes-buffer))
    (setq orgacle-notes-buffer (generate-new-buffer "*Orgacle Notes*"))
    (with-current-buffer orgacle-notes-buffer
      (erase-buffer)
      (org-mode)
      (insert notes)
      (goto-char (point-min))
      (while (re-search-forward "\\*\\* ?.* Speaker [nN]otes[ \t]*\n" nil t)
        (replace-match ""))
      (goto-char (point-min))
      (setq orgacle--notes-markers
            (let (markers)
              (while (re-search-forward "^\\* " nil t)
                (push (copy-marker (match-beginning 0) t) markers)
                (end-of-line))
              (vconcat (nreverse markers))))
      (goto-char (point-min))
      (org-narrow-to-subtree))
    orgacle-notes-buffer))

(defun orgacle-make-notes-buffer ()
  "Collect speaker notes into a buffer and show it in a new frame."
  (interactive)
  (orgacle--build-notes-buffer)
  (switch-to-buffer-other-frame orgacle-notes-buffer))

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
