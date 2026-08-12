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
  "Scroll the notes buffer to the notes for the current slide."
  (interactive)
  (when orgacle-notes-buffer
    (let* ((current-heading (org-entry-get nil "ITEM"))
           (find-me (concat "^\\*[ \t]+" (regexp-quote current-heading))))
      (with-selected-window (get-buffer-window orgacle-notes-buffer t)
        (widen)
        (goto-char (point-min))
        (re-search-forward find-me)
        (org-narrow-to-subtree)
        (recenter 0)))))

(defun orgacle--collect-notes ()
  "Return this buffer's speaker notes as Org text.
Each frame-level heading contributes a first-level heading, followed by
the body of its \"Speaker notes\" subtree when it has one."
  (let ((speaker-notes ""))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (org-next-visible-heading 1)
        (let ((current-heading (org-entry-get nil "ITEM")))
          (when (= (org-current-level) 1)
            (setq speaker-notes
                  (concat speaker-notes "* " current-heading "\n")))
          (when (string= current-heading "Speaker notes")
            (org-mark-subtree)
            (setq speaker-notes
                  (concat speaker-notes
                          (buffer-substring (point) (mark))
                          "\n"))))))
    (deactivate-mark)
    speaker-notes))

(defun orgacle-make-notes-buffer ()
  "Collect speaker notes into a buffer and show it in a new frame."
  (interactive)
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
      (org-narrow-to-subtree))
    (switch-to-buffer-other-frame orgacle-notes-buffer)))

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
